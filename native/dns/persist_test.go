package main

import (
	"context"
	"errors"
	"net/netip"
	"os"
	"strconv"
	"testing"
	"time"
)

func persistentPublisher(t *testing.T) (*publisher, *bootStamp, *int) {
	t.Helper()
	c := testConfig()
	c.Persistent = true
	for i := range c.Groups {
		c.Groups[i].Policy = c.Groups[i].Names[0]
	}
	p, err := compile(c)
	if err != nil {
		t.Fatal(err)
	}
	s := &bootStamp{"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", time.Hour}
	p.stamp = func() (bootStamp, error) { return *s, nil }
	calls := new(int)
	w := &publisher{policy: p, ledger: testLedger(t, p), leases: map[bindingKey]binding{}, commit: func(context.Context, []binding, time.Time) error { *calls++; return nil }}
	return w, s, calls
}

func TestPersistentCapacityFailsBeforeCommitOrAllocation(t *testing.T) {
	for _, bound := range []string{"identities", "bytes"} {
		t.Run(bound, func(t *testing.T) {
			w, _, commits := persistentPublisher(t)
			if err := w.ledger.loadHistory(w.policy); err != nil {
				t.Fatal(err)
			}
			if bound == "bytes" {
				w.ledger.historyBytes = maxHistoryBytes
			} else {
				for i := 0; i < maxHistory; i++ {
					w.ledger.history[strconv.Itoa(i)] = savedBinding{}
				}
			}
			before := w.ledger.data
			if _, err := w.publishName(context.Background(), 0, []netip.Addr{netip.MustParseAddr("203.0.113.80")}, 60, "protected.example"); err == nil || *commits != 0 || before != w.ledger.data {
				t.Fatal("capacity failure committed or consumed an address")
			}
		})
	}
}

func reopenPublisher(t *testing.T, w *publisher) *publisher {
	t.Helper()
	w.ledger.lock.Close()
	l, err := openLedger(w.ledger.path, w.policy.key, false)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.lock.Close() })
	return &publisher{policy: w.policy, ledger: l, leases: map[bindingKey]binding{}, commit: w.commit}
}

func TestPersistentIdentityAndBootSafety(t *testing.T) {
	w, stamp, commits := persistentPublisher(t)
	ip := []netip.Addr{netip.MustParseAddr("203.0.113.80")}
	first, err := w.publishName(context.Background(), 0, ip, 60, "protected.example")
	if err != nil {
		t.Fatal(err)
	}
	cursor := w.ledger.data.Next4
	w = reopenPublisher(t, w)
	before := *commits
	if err := w.restore(); err != nil || *commits != before+1 {
		t.Fatal("valid same-boot lease not replayed", err)
	}
	stamp.Uptime += time.Hour
	w = reopenPublisher(t, w)
	before = *commits
	if err := w.restore(); err != nil || *commits != before {
		t.Fatal("expired lease replayed", err)
	}
	again, err := w.publishName(context.Background(), 0, ip, 60, "protected.example")
	if err != nil || again[0] != first[0] || w.ledger.data.Next4 != cursor {
		t.Fatal("fresh lookup changed sticky identity", err)
	}
	stamp.Boot = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
	stamp.Uptime = time.Minute
	w = reopenPublisher(t, w)
	before = *commits
	if err := w.restore(); err != nil || *commits != before {
		t.Fatal("previous-boot mapping trusted", err)
	}
	again, err = w.publishName(context.Background(), 0, ip, 60, "protected.example")
	if err != nil || again[0] != first[0] {
		t.Fatal("revalidated mapping lost stable address", err)
	}
	other, err := w.publishName(context.Background(), 1, ip, 60, "other.example")
	if err != nil || other[0] == first[0] {
		t.Fatal("shared CDN identity crossed policy", err)
	}
}

func TestPersistentCommitFailureAndCorruptionFailClosed(t *testing.T) {
	w, _, _ := persistentPublisher(t)
	w.commit = func(context.Context, []binding, time.Time) error { return errors.New("nft failure") }
	_, err := w.publishName(context.Background(), 0, []netip.Addr{netip.MustParseAddr("203.0.113.80")}, 60, "protected.example")
	if err == nil || len(w.ledger.history) != 0 || w.ledger.data.Next4 != 2 {
		t.Fatal("failed nft commit was acknowledged or reused")
	}
	f, err := os.OpenFile(w.ledger.path+".bindings", os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString("{invalid}\n")
	f.Close()
	w = reopenPublisher(t, w)
	for i := 0; i < 2; i++ {
		if err := w.restore(); err == nil {
			t.Fatal("corrupt journal accepted on retry")
		}
	}
}

func TestPersistentTornTailDoesNotReassignAddress(t *testing.T) {
	w, _, _ := persistentPublisher(t)
	ips := []netip.Addr{netip.MustParseAddr("203.0.113.80")}
	first, err := w.publishName(context.Background(), 0, ips, 60, "protected.example")
	if err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(w.ledger.path+".bindings", os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString("{torn")
	f.Close()
	w = reopenPublisher(t, w)
	if err := w.restore(); err != nil {
		t.Fatal(err)
	}
	other, err := w.publishName(context.Background(), 1, ips, 60, "other.example")
	if err != nil || other[0] == first[0] {
		t.Fatal("torn tail reused issued identity", err)
	}
}
