package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/miekg/dns"
)

func testConfig() config {
	return config{Epoch: "0011223344556677", Listen: "127.0.0.1:1058", Upstream: "127.0.0.1:1059",
		Pools: []string{"198.18.0.0/15", "2001:2::/48"}, Exclusions: []string{"192.0.2.11/32"},
		Groups: []group{{[]string{"protected.example"}, true}, {[]string{"other.example"}, true}, {[]string{"direct.example"}, false}}}
}

func TestVirtualPolicyRequiresSeparateListenerAndPool(t *testing.T) {
	c := testConfig()
	c.Virtual = true
	if _, err := compile(c); err == nil {
		t.Fatal("virtual policy accepted ordinary DNS configuration")
	}
	c.Listen = "172.31.252.1:24053"
	c.Pools = []string{"172.31.253.0/24"}
	c.PrivatePool = c.Pools[0]
	c.Groups = c.Groups[:1]
	p, err := compile(c)
	if err != nil || !p.Virtual {
		t.Fatalf("dedicated virtual DNS configuration was rejected: %v", err)
	}
	b := []binding{{group: 0, real: netip.MustParseAddr("203.0.113.80"), fake: netip.MustParseAddr("172.31.253.1"), until: time.Now().Add(time.Minute)}}
	batch := transaction("pkc_virtual_guard", p.Epoch, b, time.Now())
	if strings.Contains(batch, "podkopchik_native") || strings.Count(batch, "inet pkc_virtual_guard") != 4 {
		t.Fatal("virtual DNS transaction did not stay in the dedicated table")
	}
}

func TestVirtualAllocationWindowExhaustion(t *testing.T) {
	c := testConfig()
	c.Virtual, c.Listen = true, "172.31.252.1:24053"
	c.Pools, c.PrivatePool = []string{"172.31.253.0/24"}, "172.31.253.0/24"
	c.VirtualWindow = []uint32{2, 32}
	if _, err := compile(c); err == nil {
		t.Fatal("window may not cover addresses issued in earlier pilots")
	}
	c.VirtualWindow = []uint32{32, 32}
	p, err := compile(c)
	if err != nil {
		t.Fatal(err)
	}
	commits := 0
	pub := publisher{policy: p, ledger: testLedger(t, p), leases: map[bindingKey]binding{},
		commit: func(context.Context, []binding, time.Time) error { commits++; return nil }}
	addresses, err := pub.publish(context.Background(), 0, []netip.Addr{netip.MustParseAddr("203.0.113.80")}, 60)
	if err != nil || len(addresses) != 1 || addresses[0].String() != "172.31.253.32" || pub.ledger.data.Next4 != 33 {
		t.Fatal("publisher did not use the reserved window", addresses, err)
	}
	if _, err := pub.publish(context.Background(), 0, []netip.Addr{netip.MustParseAddr("203.0.113.81")}, 60); err == nil || commits != 1 {
		t.Fatal("publisher spilled beyond the reserved window")
	}
}

func TestRetiredPoolNeverReturnedByDirectDNS(t *testing.T) {
	c := testConfig()
	c.RetiredPools = []string{"172.31.253.0/24"}
	p, err := compile(c)
	if err != nil {
		t.Fatal(err)
	}
	r := testResolver(t, p, func(context.Context, []binding, time.Time) error {
		t.Fatal("direct or rejected query must not publish")
		return nil
	}, func(_ context.Context, q dns.Question) (*dns.Msg, error) {
		ip := "192.168.1.20"
		if q.Name != "ordinary.direct.example." {
			ip = "172.31.253.32"
		}
		return fixture(q, q.Name+" 90 IN A "+ip), nil
	})
	addr := startTestDNS(t, r)
	requireAnswer(t, addr, "tcp", "stale.direct.example.", dns.TypeA, dns.RcodeServerFailure, 0)
	requireAnswer(t, addr, "udp", "stale.unmatched.example.", dns.TypeA, dns.RcodeServerFailure, 0)
	requireAnswer(t, addr, "udp", "ordinary.direct.example.", dns.TypeA, dns.RcodeSuccess, 1)
}

func testLedger(t *testing.T, p *policy) *ledger {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "state")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	l, err := openLedger(filepath.Join(dir, "watermark"), p.key, true)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.lock.Close() })
	return l
}

func testResolver(t *testing.T, p *policy, commit func(context.Context, []binding, time.Time) error,
	upstream func(context.Context, dns.Question) (*dns.Msg, error)) *resolver {
	t.Helper()
	return &resolver{policy: p, writer: &publisher{policy: p, ledger: testLedger(t, p), leases: map[bindingKey]binding{}, commit: commit},
		upstream: upstream, cache: map[questionKey]result{}, slots: make(chan struct{}, 64)}
}

func rr(s string) dns.RR {
	r, err := dns.NewRR(s)
	if err != nil {
		panic(err)
	}
	return r
}

func fixture(q dns.Question, rs ...string) *dns.Msg {
	m := new(dns.Msg).SetReply(new(dns.Msg).SetQuestion(q.Name, q.Qtype))
	for _, s := range rs {
		m.Answer = append(m.Answer, rr(s))
	}
	return m
}

func startTestDNS(t *testing.T, h dns.Handler) string {
	t.Helper()
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	u, err := net.ListenPacket("udp4", l.Addr().String())
	if err != nil {
		l.Close()
		t.Fatal(err)
	}
	for _, s := range []*dns.Server{{Listener: l, Handler: h}, {PacketConn: u, Handler: h, UDPSize: 1232}} {
		ready := make(chan struct{})
		s.NotifyStartedFunc = func() { close(ready) }
		go s.ActivateAndServe()
		select {
		case <-ready:
		case <-time.After(time.Second):
			t.Fatal("DNS listener did not become ready")
		}
		t.Cleanup(func() { _ = s.Shutdown() })
	}
	return l.Addr().String()
}

func exchange(addr, protocol, name string, qt uint16) (*dns.Msg, error) {
	c := dns.Client{Net: protocol, Timeout: 4 * time.Second}
	m, _, err := c.Exchange(new(dns.Msg).SetQuestion(name, qt), addr)
	return m, err
}

func requireAnswer(t *testing.T, addr, protocol, name string, qt uint16, code, count int) *dns.Msg {
	t.Helper()
	m, err := exchange(addr, protocol, name, qt)
	if err != nil || m.Rcode != code || len(m.Answer) != count {
		t.Fatalf("%s/%s: DNS reply=%v, err=%v", name, protocol, m, err)
	}
	return m
}

func TestLocalNamesAndReverseDoNotPublishAddresses(t *testing.T) {
	p, _ := compile(testConfig())
	r := testResolver(t, p, func(context.Context, []binding, time.Time) error {
		return errors.New("local DNS should not require nftables")
	}, func(_ context.Context, q dns.Question) (*dns.Msg, error) {
		if q.Qtype == dns.TypePTR {
			m := fixture(q, q.Name+" 600 IN PTR printer.lan.", q.Name+" 90 IN A 203.0.113.80")
			m.Extra = []dns.RR{rr("printer.lan. 90 IN A 192.168.1.20")}
			return m, nil
		}
		return fixture(q, q.Name+" 90 IN A 192.168.1.20"), nil
	})
	addr := startTestDNS(t, r)
	for _, proto := range []string{"udp", "tcp"} {
		m := requireAnswer(t, addr, proto, "printer.", dns.TypeA, dns.RcodeSuccess, 1)
		if m.Answer[0].(*dns.A).A.String() != "192.168.1.20" {
			t.Fatal("local address lost")
		}
		m = requireAnswer(t, addr, proto, "20.1.168.192.in-addr.arpa.", dns.TypePTR, dns.RcodeSuccess, 1)
		if m.Answer[0].(*dns.PTR).Ptr != "printer.lan." || m.Answer[0].Header().Ttl > maxTTL || len(m.Extra) > 0 {
			t.Fatal("PTR answer not sanitized")
		}
		requireAnswer(t, addr, proto, "protected.example.", dns.TypePTR, dns.RcodeRefused, 0)
	}
}

func TestExpireFreesLeaseButDoesNotReuseAddress(t *testing.T) {
	p, _ := compile(testConfig())
	r := testResolver(t, p, func(context.Context, []binding, time.Time) error { return nil }, nil)
	ips := []netip.Addr{netip.MustParseAddr("203.0.113.80")}
	first, err := r.writer.publish(t.Context(), 0, ips, 1)
	if err != nil {
		t.Fatal(err)
	}
	r.writer.expire(time.Now().Add(leaseGrace + 2*time.Second))
	if len(r.writer.leases) != 0 || r.writer.ledger.data.Next4 != 2 {
		t.Fatal("sweep did not release memory or rewound the watermark")
	}
	second, err := r.writer.publish(t.Context(), 0, ips, 1)
	if err != nil || first[0] == second[0] {
		t.Fatal("expired address was reused", err)
	}
}

func TestPrivatePoolAdmissionAndExhaustion(t *testing.T) {
	c := testConfig()
	c.Pools = []string{"172.31.253.0/24"}
	if _, err := compile(c); err == nil {
		t.Fatal("private pool admitted without an exact opt-in")
	}
	c.PrivatePool = c.Pools[0]
	p, err := compile(c)
	if err != nil {
		t.Fatal(err)
	}
	for n := uint32(1); n <= 254; n++ {
		a, err := addressAt(p.pools[true], n)
		if err != nil || a.As4()[3] != byte(n) {
			t.Fatal("unexpected private lease capacity", n, err)
		}
	}
	if p.safeReal(netip.MustParseAddr("172.31.254.1")) {
		t.Fatal("private target incorrectly admitted for DNAT")
	}
	c.Exclusions = append(c.Exclusions, "172.31.0.0/16")
	if _, err := compile(c); err == nil {
		t.Fatal("overlapping remote private network admitted")
	}
	var commits atomic.Int32
	r := testResolver(t, p, func(context.Context, []binding, time.Time) error { commits.Add(1); return nil },
		func(_ context.Context, q dns.Question) (*dns.Msg, error) {
			ip := "203.0.113.80"
			if q.Name == "new.protected.example." {
				ip = "203.0.113.81"
			}
			return fixture(q, q.Name+" 90 IN A "+ip), nil
		})
	next := r.writer.ledger.data
	next.Next4 = 254
	if err := r.writer.ledger.save(next); err != nil {
		t.Fatal(err)
	}
	addr := startTestDNS(t, r)
	m := requireAnswer(t, addr, "udp", "protected.example.", dns.TypeA, dns.RcodeSuccess, 1)
	if m.Answer[0].(*dns.A).A.String() != "172.31.253.254" {
		t.Fatal("final address incorrect")
	}
	requireAnswer(t, addr, "tcp", "new.protected.example.", dns.TypeA, dns.RcodeServerFailure, 0)
	requireAnswer(t, addr, "tcp", "protected.example.", dns.TypeA, dns.RcodeSuccess, 1)
	r.writer.mu.Lock()
	watermark := r.writer.ledger.data.Next4
	r.writer.mu.Unlock()
	if commits.Load() != 2 || watermark != 255 {
		t.Fatal("pool exhaustion recycled or published an address")
	}
}

func TestNoReplyBeforeKernelAckAndNoRealIPOnFailure(t *testing.T) {
	p, _ := compile(testConfig())
	entered, allow := make(chan struct{}), make(chan struct{})
	var fail atomic.Bool
	r := testResolver(t, p, func(_ context.Context, b []binding, _ time.Time) error {
		if fail.Load() {
			return errors.New("nft set missing")
		}
		if b[0].group == 0 {
			select {
			case <-entered:
			default:
				close(entered)
			}
			<-allow
		}
		return nil
	}, func(_ context.Context, q dns.Question) (*dns.Msg, error) {
		return fixture(q, q.Name+" 90 IN A 203.0.113.80"), nil
	})
	addr := startTestDNS(t, r)
	done := make(chan *dns.Msg, 1)
	go func() { m, _ := exchange(addr, "udp", "protected.example.", dns.TypeA); done <- m }()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("publisher did not run")
	}
	select {
	case <-done:
		t.Fatal("DNS reply before nft acknowledgement")
	case <-time.After(50 * time.Millisecond):
	}
	close(allow)
	if m := <-done; m == nil || m.Rcode != 0 || len(m.Answer) != 1 || !strings.Contains(m.Answer[0].String(), "198.18.0.1") {
		t.Fatalf("no committed synthetic answer: %v", m)
	}
	fail.Store(true)
	for _, proto := range []string{"udp", "tcp"} {
		requireAnswer(t, addr, proto, "protected.example.", dns.TypeA, dns.RcodeServerFailure, 0)
		m := requireAnswer(t, addr, proto, "direct.example.", dns.TypeA, dns.RcodeSuccess, 1)
		if !strings.Contains(m.Answer[0].String(), "203.0.113.80") {
			t.Fatal("direct DNS was disrupted by protected nft failure")
		}
	}
}

func TestAliasTTLCacheAndConcurrentClients(t *testing.T) {
	p, _ := compile(testConfig())
	var lookups, commits atomic.Int32
	r := testResolver(t, p, func(_ context.Context, b []binding, _ time.Time) error {
		commits.Add(1)
		if len(b) != 1 || b[0].group != 0 || b[0].real.String() != "2001:db8::80" {
			return errors.New("wrong reachable IPv6 answer")
		}
		return nil
	}, func(_ context.Context, q dns.Question) (*dns.Msg, error) {
		lookups.Add(1)
		return fixture(q, q.Name+" 3 IN CNAME sub.protected.example.", "sub.protected.example. 90 IN CNAME cdn.example.",
			"cdn.example. 20 IN AAAA 2001:db8::80", "unrelated.example. 60 IN AAAA 2001:db8::81"), nil
	})
	addr := startTestDNS(t, r)
	var wg sync.WaitGroup
	for i := range 24 {
		wg.Go(func() {
			proto := []string{"udp", "tcp"}[i%2]
			m, err := exchange(addr, proto, "outside.example.", dns.TypeAAAA)
			if err != nil || m.Rcode != 0 || len(m.Answer) != 1 || m.Answer[0].Header().Ttl > 3 ||
				!strings.Contains(m.Answer[0].String(), "2001:2::1") || m.AuthenticatedData || len(m.Extra) > 0 {
				t.Errorf("bad synthetic alias response: %v %v", m, err)
			}
		})
	}
	wg.Wait()
	if lookups.Load() != 1 || commits.Load() != 24 || r.writer.ledger.data.Next6 != 2 {
		t.Fatalf("unexpected deduplication: upstream=%d nft=%d watermark=%d", lookups.Load(), commits.Load(), r.writer.ledger.data.Next6)
	}
	k := questionKey{"outside.example.", dns.TypeAAAA}
	r.mu.Lock()
	x := r.cache[k]
	x.until = time.Now().Add(-time.Second)
	r.cache[k] = x
	r.mu.Unlock()
	requireAnswer(t, addr, "tcp", k.name, k.typeCode, 0, 1)
	if lookups.Load() != 2 {
		t.Fatal("expired DNS cache not refreshed")
	}
}

func TestRejectConflictingAliasAndProtectedRebinding(t *testing.T) {
	p, _ := compile(testConfig())
	for _, tc := range []struct {
		name string
		data []string
	}{
		{"cross-policy", []string{"protected.example. 60 IN CNAME other.example.", "other.example. 30 IN A 203.0.113.80"}},
		{"cycle", []string{"protected.example. 30 IN CNAME loop.example.", "loop.example. 30 IN CNAME protected.example."}},
		{"local", []string{"protected.example. 30 IN A 192.168.1.1"}},
		{"endpoint", []string{"protected.example. 30 IN A 192.0.2.11"}},
		{"fake", []string{"protected.example. 30 IN A 198.18.3.1"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := testResolver(t, p, func(context.Context, []binding, time.Time) error {
				t.Error("unsafe upstream data reached nft")
				return nil
			}, func(_ context.Context, q dns.Question) (*dns.Msg, error) { return fixture(q, tc.data...), nil })
			requireAnswer(t, startTestDNS(t, r), "tcp", "protected.example.", dns.TypeA, dns.RcodeServerFailure, 0)
		})
	}
}

func TestTruncationHintsAndUpstreamTCPRetry(t *testing.T) {
	var tcpCalls, writes atomic.Int32
	up := startTestDNS(t, dns.HandlerFunc(func(w dns.ResponseWriter, q *dns.Msg) {
		m := new(dns.Msg).SetReply(q)
		if w.LocalAddr().Network() == "udp" {
			m.Truncated = true
		} else {
			tcpCalls.Add(1)
			for i := 1; i <= 32; i++ {
				m.Answer = append(m.Answer, rr(fmt.Sprintf("%s 30 IN AAAA 2001:db8::%x", q.Question[0].Name, i)))
			}
		}
		_ = w.WriteMsg(m)
	}))
	p, _ := compile(testConfig())
	r := testResolver(t, p, func(context.Context, []binding, time.Time) error { writes.Add(1); return nil }, makeUpstream(up))
	addr := startTestDNS(t, r)
	if m := requireAnswer(t, addr, "udp", "protected.example.", dns.TypeAAAA, 0, 0); !m.Truncated || writes.Load() != 0 {
		t.Fatal("oversized UDP committed or omitted TC")
	}
	requireAnswer(t, addr, "tcp", "protected.example.", dns.TypeAAAA, 0, 32)
	for _, qt := range []uint16{dns.TypeHTTPS, dns.TypeSVCB} {
		requireAnswer(t, addr, "udp", "protected.example.", qt, 0, 0)
	}
	requireAnswer(t, addr, "tcp", "protected.example.", dns.TypeANY, dns.RcodeRefused, 0)
	if tcpCalls.Load() != 1 || writes.Load() != 1 {
		t.Fatalf("unexpected upstream TCP calls=%d, nft transactions=%d", tcpCalls.Load(), writes.Load())
	}
}

func TestLedgerNoReuseOnErrorRestartAndExpiry(t *testing.T) {
	cfg := testConfig()
	cfg.Pools = []string{"198.18.0.0/29"}
	p, _ := compile(cfg)
	l := testLedger(t, p)
	if _, err := openLedger(l.path, p.key, false); err == nil {
		t.Fatal("two writers acquired one generation")
	}
	ctx := context.Background()
	commit := func(context.Context, []binding, time.Time) error { return nil }
	w := publisher{policy: p, ledger: l, leases: map[bindingKey]binding{}, commit: commit}
	ip := netip.MustParseAddr("203.0.113.80")
	first, err := w.publish(ctx, 0, []netip.Addr{ip}, 3)
	if err != nil || first[0].String() != "198.18.0.1" {
		t.Fatal(first, err)
	}
	w.commit = func(context.Context, []binding, time.Time) error { return errors.New("uncertain kernel result") }
	if _, err = w.publish(ctx, 1, []netip.Addr{ip}, 3); err == nil || l.data.Next4 != 3 {
		t.Fatal("failed transaction did not reserve its uncertain address")
	}
	l.lock.Close()
	if _, err = openLedger(l.path, p.key, true); err == nil {
		t.Fatal("initializing a used ledger succeeded")
	}
	if _, err = openLedger(l.path, "wrong-key", false); err == nil {
		t.Fatal("ledger accepted a changed layout")
	}
	newL, err := openLedger(l.path, p.key, false)
	if err != nil {
		t.Fatal(err)
	}
	defer newL.lock.Close()
	w2 := publisher{policy: p, ledger: newL, leases: map[bindingKey]binding{}, commit: commit}
	for i := 3; i <= 6; i++ {
		b, err := w2.publish(ctx, 0, []netip.Addr{ip}, 3)
		if err != nil || b[0].String() != fmt.Sprintf("198.18.0.%d", i) {
			t.Fatal("address reused", b, err)
		}
		v := w2.leases[bindingKey{0, ip}]
		v.until = time.Now().Add(-time.Second)
		w2.leases[bindingKey{0, ip}] = v
	}
	if _, err = w2.publish(ctx, 0, []netip.Addr{ip}, 3); err == nil {
		t.Fatal("exhaustion did not fail closed")
	}
}

func TestDNSDestinationChangeKeepsOldLeaseIdentity(t *testing.T) {
	p, err := compile(testConfig())
	if err != nil {
		t.Fatal(err)
	}
	oldIP := netip.MustParseAddr("203.0.113.80")
	newIP := netip.MustParseAddr("203.0.113.81")
	seen := map[netip.Addr]netip.Addr{}
	w := publisher{policy: p, ledger: testLedger(t, p), leases: map[bindingKey]binding{},
		commit: func(_ context.Context, b []binding, _ time.Time) error {
			for _, v := range b {
				if old, ok := seen[v.fake]; ok && old != v.real {
					return errors.New("changed the destination of a previously issued address")
				}
				seen[v.fake] = v.real
			}
			return nil
		}}
	first, err := w.publish(context.Background(), 0, []netip.Addr{oldIP}, 15)
	if err != nil {
		t.Fatal(err)
	}
	second, err := w.publish(context.Background(), 0, []netip.Addr{newIP}, 15)
	if err != nil || len(second) != 1 || first[0] == second[0] || seen[first[0]] != oldIP || seen[second[0]] != newIP {
		t.Fatal("DNS destination change reused or rewrote an active lease", first, second, err)
	}
}

func TestPolicyRejectsOverlapsAndInjection(t *testing.T) {
	for _, modify := range []func(*config){
		func(c *config) { c.Epoch = "00000000; flush ruleset" },
		func(c *config) { c.Pools = []string{"192.168.1.0/24"} },
		func(c *config) { c.Exclusions = []string{"198.18.3.9/32"} },
		func(c *config) { c.Groups[1].Names = c.Groups[0].Names },
		func(c *config) { c.Groups[1].Names = []string{"other\\.example"} },
		func(c *config) { c.Listen6 = "[::ffff:127.0.0.1]:1058" },
		func(c *config) { c.Listen6 = "[::1]:1059" },
		func(c *config) { c.Listen6 = "[::]:1058" },
		func(c *config) { c.Listen6, c.Upstream = "[::1]:1058", "[0:0:0:0:0:0:0:1]:1058" },
	} {
		c := testConfig()
		modify(&c)
		if _, err := compile(c); err == nil {
			t.Fatalf("invalid policy accepted: %#v", c)
		}
	}
}
