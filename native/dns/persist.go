package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

const maxHistory = 8192
const maxJournal = 4 << 20
const maxHistoryBytes = 2 << 20

type bootStamp struct {
	Boot   string
	Uptime time.Duration
}
type savedBinding struct {
	Name   string `json:"name"`
	Policy string `json:"policy"`
	Real   string `json:"real"`
	Fake   string `json:"fake"`
	Boot   string `json:"boot"`
	Until  int64  `json:"until"`
}
type journalRecord struct {
	Data   json.RawMessage `json:"data"`
	SHA256 string          `json:"sha256"`
}

func systemBootStamp() (bootStamp, error) {
	b, err := os.ReadFile("/proc/sys/kernel/random/boot_id")
	if err != nil {
		return bootStamp{}, err
	}
	u, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return bootStamp{}, err
	}
	parts := strings.Fields(string(u))
	if len(parts) < 1 {
		return bootStamp{}, errors.New("missing monotonic clock")
	}
	f, err := strconv.ParseFloat(parts[0], 64)
	boot := strings.TrimSpace(string(b))
	if err != nil || f < 0 || len(boot) != 36 {
		return bootStamp{}, errors.New("invalid boot clock")
	}
	return bootStamp{boot, time.Duration(f * float64(time.Second))}, nil
}

func historyKey(name, policy, real string) string { return policy + "|" + name + "|" + real }

func (l *ledger) loadHistory(p *policy) error {
	if l.history != nil {
		return nil
	}
	history := map[string]savedBinding{}
	var size int64
	f, err := privateOpen(l.path+".bindings", unix.O_CREAT|unix.O_RDWR|unix.O_APPEND)
	if err != nil {
		return err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || info.Size() > maxJournal {
		return errors.New("DNS binding journal exceeds its bound")
	}
	r := bufio.NewReader(f)
	var offset int64
	owners := map[string]string{}
	for {
		line, err := r.ReadBytes('\n')
		if err == io.EOF {
			// Allocation watermark was fsynced first. A torn unacknowledged
			// final record can be discarded, but its address stays reserved.
			if len(line) != 0 {
				if err := f.Truncate(offset); err != nil {
					return err
				}
				if err := f.Sync(); err != nil {
					return err
				}
			}
			l.history = history
			l.historyBytes = size
			return nil
		}
		if err != nil || len(line) > 2048 {
			return errors.New("invalid DNS journal record")
		}
		var frame journalRecord
		var v savedBinding
		if json.Unmarshal(line, &frame) != nil || fmt.Sprintf("%x", sha256.Sum256(frame.Data)) != frame.SHA256 ||
			json.Unmarshal(frame.Data, &v) != nil || !validName(v.Name) || len(v.Policy) > 80 || v.Policy == "" || strings.ContainsAny(v.Policy, "|\r\n") || len(v.Boot) != 36 || v.Until < 0 {
			return errors.New("untrusted DNS binding journal")
		}
		real, e1 := netip.ParseAddr(v.Real)
		fake, e2 := netip.ParseAddr(v.Fake)
		if e1 != nil || e2 != nil || real.Is4() != fake.Is4() || !p.pools[fake.Is4()].Contains(fake) || fake == p.pools[fake.Is4()].Addr() {
			return errors.New("invalid journal address")
		}
		cursor := l.data.Next6
		if fake.Is4() {
			cursor = l.data.Next4
		}
		found := false
		// Derive the offset without allowing a journal entry beyond the
		// durable watermark to create an allocation alias.
		if fake.Is4() {
			a := fake.As4()
			b := p.pools[true].Addr().As4()
			n := uint32(a[0])<<24 | uint32(a[1])<<16 | uint32(a[2])<<8 | uint32(a[3])
			base := uint32(b[0])<<24 | uint32(b[1])<<16 | uint32(b[2])<<8 | uint32(b[3])
			found = n > base && n-base < cursor
		} else {
			a, b := fake.As16(), p.pools[false].Addr().As16()
			lo, base := binary.BigEndian.Uint64(a[8:]), binary.BigEndian.Uint64(b[8:])
			found = string(a[:8]) == string(b[:8]) && lo > base && lo-base < uint64(cursor)
		}
		if !found {
			return errors.New("journal exceeds allocation watermark")
		}
		key := historyKey(v.Name, v.Policy, v.Real)
		if old, ok := owners[v.Fake]; ok && old != key {
			return errors.New("synthetic address identity changed")
		}
		if old, ok := history[key]; ok && old.Fake != v.Fake {
			return errors.New("sticky binding changed address")
		}
		owners[v.Fake] = key
		if old, ok := history[key]; ok {
			size -= int64(len(encodeRecord(old)))
		}
		size += int64(len(encodeRecord(v)))
		history[key] = v
		if len(history) > maxHistory || size > maxHistoryBytes {
			return errors.New("DNS binding history exhausted")
		}
		offset += int64(len(line))
	}
}

func encodeRecord(v savedBinding) []byte {
	b, _ := json.Marshal(v)
	out, _ := json.Marshal(journalRecord{b, fmt.Sprintf("%x", sha256.Sum256(b))})
	return append(out, '\n')
}

func (l *ledger) recordDelta(v savedBinding) int64 {
	n := int64(len(encodeRecord(v)))
	if old, ok := l.history[historyKey(v.Name, v.Policy, v.Real)]; ok {
		n -= int64(len(encodeRecord(old)))
	}
	return n
}

func (l *ledger) record(v savedBinding) error {
	key := historyKey(v.Name, v.Policy, v.Real)
	if old, ok := l.history[key]; ok && old.Boot == v.Boot && old.Fake == v.Fake && old.Until >= v.Until-int64(time.Second) {
		return nil
	}
	if _, ok := l.history[key]; !ok && len(l.history) >= maxHistory {
		return errors.New("DNS binding history exhausted")
	}
	delta := l.recordDelta(v)
	if l.historyBytes+delta > maxHistoryBytes {
		return errors.New("DNS binding history capacity exhausted")
	}
	f, err := privateOpen(l.path+".bindings", unix.O_WRONLY|unix.O_APPEND)
	if err != nil {
		return err
	}
	b := encodeRecord(v)
	n, err := f.Write(b)
	if err == nil && n != len(b) {
		err = io.ErrShortWrite
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	l.history[key] = v
	l.historyBytes += delta
	info, err := os.Stat(l.path + ".bindings")
	if err != nil {
		return err
	}
	if info.Size() < 3<<20 {
		return nil
	}
	tmp, err := os.CreateTemp(filepath.Dir(l.path), ".bindings-")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	keys := make([]string, 0, len(l.history))
	for k := range l.history {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if _, err = tmp.Write(encodeRecord(l.history[k])); err != nil {
			tmp.Close()
			return err
		}
	}
	if err = tmp.Sync(); err == nil {
		err = tmp.Close()
	} else {
		tmp.Close()
	}
	if err == nil {
		err = os.Rename(tmp.Name(), l.path+".bindings")
	}
	if err == nil {
		err = syncDir(l.path)
	}
	return err
}

func (p *publisher) restore() error {
	if !p.policy.Persistent {
		return nil
	}
	if err := p.ledger.loadHistory(p.policy); err != nil {
		return err
	}
	s, err := p.policy.stamp()
	if err != nil {
		return err
	}
	var bindings []binding
	for _, v := range p.ledger.history {
		g := p.policy.group(v.Name)
		if v.Boot != s.Boot || v.Until <= int64(s.Uptime) || g < 0 || !p.policy.Groups[g].Protected || p.policy.Groups[g].Policy != v.Policy {
			continue
		}
		real, _ := netip.ParseAddr(v.Real)
		fake, _ := netip.ParseAddr(v.Fake)
		if !p.policy.safeReal(real) {
			continue
		}
		remaining := time.Duration(v.Until) - s.Uptime
		if remaining > time.Duration(maxTTL)*time.Second+leaseGrace {
			return errors.New("untrusted lease lifetime")
		}
		bindings = append(bindings, binding{group: g, real: real, fake: fake, until: time.Now().Add(remaining)})
	}
	if len(bindings) == 0 {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	for start := 0; start < len(bindings); start += 128 {
		if err := p.commit(ctx, bindings[start:min(start+128, len(bindings))], time.Now()); err != nil {
			return err
		}
	}
	return nil
}
