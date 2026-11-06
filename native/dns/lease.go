package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

const leaseGrace = 30 * time.Second

type watermark struct {
	Policy string `json:"policy"`
	Next4  uint32 `json:"next4"`
	Next6  uint32 `json:"next6"`
}

type ledger struct {
	path string
	lock *os.File
	data watermark
}

func openLedger(path, key string, init bool) (*ledger, error) {
	var dir unix.Stat_t
	if err := unix.Lstat(filepath.Dir(path), &dir); err != nil || dir.Mode&unix.S_IFMT != unix.S_IFDIR ||
		dir.Mode&0777 != 0700 || int(dir.Uid) != os.Geteuid() {
		return nil, errors.New("ledger requires a private directory")
	}
	lock, err := privateOpen(path+".lock", unix.O_CREAT|unix.O_RDWR)
	if err != nil {
		return nil, err
	}
	l := &ledger{path: path, lock: lock}
	if err = unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err == nil {
		if init {
			// Never reset a used generation, even if the existing file is invalid.
			var f *os.File
			if f, err = privateOpen(path, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL); err == nil {
				l.data = watermark{key, 1, 1}
				err = writeState(f, l.data)
				if err == nil {
					err = syncDir(path)
				}
			}
		} else {
			var f *os.File
			if f, err = privateOpen(path, unix.O_RDONLY); err == nil {
				defer f.Close()
				if info, e := f.Stat(); e != nil || info.Size() > 512 {
					err = errors.New("invalid ledger size")
				} else if err = json.NewDecoder(f).Decode(&l.data); err == nil && (l.data.Policy != key || l.data.Next4 < 1 || l.data.Next6 < 1 || l.data.Next4 > maxOffsets+1 || l.data.Next6 > maxOffsets+1) {
					err = errors.New("ledger generation mismatch or invalid watermark")
				}
			}
		}
	}
	if err != nil {
		lock.Close()
		return nil, err
	}
	return l, nil
}

func privateOpen(path string, flags int) (*os.File, error) {
	fd, err := unix.Open(path, flags|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0600)
	if err != nil {
		return nil, err
	}
	var s unix.Stat_t
	if err = unix.Fstat(fd, &s); err != nil || s.Mode&unix.S_IFMT != unix.S_IFREG || s.Mode&0777 != 0600 || s.Nlink != 1 || int(s.Uid) != os.Geteuid() {
		unix.Close(fd)
		return nil, errors.New("unsafe ledger file")
	}
	return os.NewFile(uintptr(fd), path), nil
}

func writeState(f *os.File, s watermark) error {
	err := json.NewEncoder(f).Encode(s)
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	return closeErr
}

func syncDir(path string) error {
	d, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

func (l *ledger) save(s watermark) error {
	f, err := os.CreateTemp(filepath.Dir(l.path), ".lease-state-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err = writeState(f, s); err == nil {
		err = os.Rename(f.Name(), l.path)
	}
	if err == nil {
		err = syncDir(l.path)
	}
	if err == nil {
		l.data = s
	}
	return err
}

func addressAt(pool netip.Prefix, n uint32) (netip.Addr, error) {
	if !pool.IsValid() || n > maxOffsets {
		return netip.Addr{}, errors.New("synthetic pool exhausted or unavailable")
	}
	bits := pool.Addr().BitLen() - pool.Bits()
	if bits <= 17 && uint64(n)+1 >= uint64(1)<<bits {
		return netip.Addr{}, errors.New("synthetic pool exhausted")
	}
	if pool.Addr().Is4() {
		b := pool.Addr().As4()
		binary.BigEndian.PutUint32(b[:], binary.BigEndian.Uint32(b[:])+n)
		return netip.AddrFrom4(b), nil
	}
	b := pool.Addr().As16()
	binary.BigEndian.PutUint64(b[8:], binary.BigEndian.Uint64(b[8:])+uint64(n))
	return netip.AddrFrom16(b), nil
}

type binding struct {
	group      int
	real, fake netip.Addr
	until      time.Time
}

type bindingKey struct {
	group int
	real  netip.Addr
}

type publisher struct {
	mu       sync.Mutex
	policy   *policy
	ledger   *ledger
	leases   map[bindingKey]binding
	commit   func(context.Context, []binding, time.Time) error
	poisoned bool
}

func (p *publisher) expire(now time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for key, lease := range p.leases {
		if !lease.until.After(now) {
			delete(p.leases, key)
		}
	}
}

func (p *publisher) publish(ctx context.Context, group int, ips []netip.Addr, ttl uint32) ([]netip.Addr, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.poisoned || ctx.Err() != nil {
		return nil, errors.New("DNS publisher unavailable")
	}
	now := time.Now()
	until := now.Add(time.Duration(ttl)*time.Second + leaseGrace)
	next := p.ledger.data
	bindings := make([]binding, 0, len(ips))
	fake := make([]netip.Addr, 0, len(ips))
	for _, ip := range ips {
		if !p.policy.safeReal(ip) {
			return nil, errors.New("protected answer overlaps a forbidden destination")
		}
		key := bindingKey{group, ip}
		b := p.leases[key]
		if !b.until.After(now) {
			cursor := &next.Next6
			if ip.Is4() {
				cursor = &next.Next4
				if w := p.policy.VirtualWindow; len(w) == 2 {
					*cursor = max(*cursor, w[0])
					if *cursor > w[1] {
						return nil, errors.New("virtual address allocation window exhausted")
					}
				}
			}
			addr, err := addressAt(p.policy.pools[ip.Is4()], *cursor)
			if err != nil {
				return nil, err
			}
			(*cursor)++
			b = binding{group: group, real: ip, fake: addr}
		}
		b.until = maxTime(b.until, until)
		bindings = append(bindings, b)
		fake = append(fake, b.fake)
	}
	if next != p.ledger.data {
		if err := p.ledger.save(next); err != nil {
			p.poisoned = true
			return nil, err
		}
	}
	// A failed or ambiguous acknowledgement may burn addresses, never reuse them.
	if err := p.commit(ctx, bindings, time.Now()); err != nil {
		return nil, err
	}
	for _, b := range bindings {
		p.leases[bindingKey{b.group, b.real}] = b
	}
	return fake, nil
}

func maxTime(a, b time.Time) time.Time {
	if a.After(b) {
		return a
	}
	return b
}

func transaction(table, epoch string, bindings []binding, now time.Time) string {
	var lines strings.Builder
	for _, b := range bindings {
		f := "6"
		if b.fake.Is4() {
			f = "4"
		}
		ttl := max(int64(1), int64((b.until.Sub(now)+time.Second-1)/time.Second))
		base := "inet " + table + " s_" + epoch
		mapping := base + "_m" + f
		set := fmt.Sprintf("%s_g%d_%s", base, b.group, f)
		fmt.Fprintf(&lines, "destroy element %s { %s }\ndestroy element %s { %s }\n", mapping, b.fake, set, b.fake)
		fmt.Fprintf(&lines, "create element %s { %s timeout %ds : %s }\ncreate element %s { %s timeout %ds }\n", mapping, b.fake, ttl, b.real, set, b.fake, ttl)
	}
	return lines.String()
}

func nftCommit(p *policy) func(context.Context, []binding, time.Time) error {
	table := "podkopchik_native"
	if p.Virtual {
		table = "pkc_virtual_guard"
	}
	return func(ctx context.Context, b []binding, now time.Time) error {
		return nftTransaction(ctx, transaction(table, p.Epoch, b, now))
	}
}

func nftTransaction(ctx context.Context, batch string) error {
	cmd := exec.CommandContext(ctx, "/usr/sbin/nft", "-f", "-")
	cmd.Stdin = strings.NewReader(batch)
	if err := cmd.Run(); err != nil {
		return errors.New("nftables transaction not acknowledged")
	}
	return nil
}
