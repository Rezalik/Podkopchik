package main

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/miekg/dns"
	"golang.org/x/sync/singleflight"
)

const maxTTL = 300

type result struct {
	rcode int
	group int
	ips   []netip.Addr
	until time.Time
}

func matchingReply(q dns.Question, m *dns.Msg) bool {
	return m != nil && m.Response && !m.Truncated && m.Opcode == dns.OpcodeQuery && len(m.Question) == 1 &&
		strings.EqualFold(m.Question[0].Name, q.Name) && m.Question[0].Qtype == q.Qtype && m.Question[0].Qclass == q.Qclass
}

func inspect(p *policy, q dns.Question, m *dns.Msg, now time.Time) (result, error) {
	if !matchingReply(q, m) {
		return result{}, errors.New("invalid DNS response")
	}
	r := result{rcode: m.Rcode, group: -1}
	if r.rcode == dns.RcodeNameError {
		return r, nil
	}
	if r.rcode != dns.RcodeSuccess || len(m.Answer) > 128 {
		return result{}, errors.New("DNS lookup failed")
	}
	n := strings.ToLower(q.Name)
	seen := make(map[string]bool)
	ttl := uint32(maxTTL)
	for {
		if seen[n] || len(seen) == 16 || !validQuestionName(strings.TrimSuffix(n, ".")) {
			return result{}, errors.New("invalid DNS alias chain")
		}
		seen[n] = true
		if i := p.group(n); i >= 0 && p.Groups[i].Protected {
			if r.group >= 0 && i != r.group {
				return result{}, errors.New("DNS alias crosses protected policies")
			}
			r.group = i
		}
		var alias string
		for _, rr := range m.Answer {
			h := rr.Header()
			if !strings.EqualFold(h.Name, n) || h.Class != dns.ClassINET {
				continue
			}
			if c, ok := rr.(*dns.CNAME); ok {
				if alias != "" && !strings.EqualFold(alias, c.Target) {
					return result{}, errors.New("ambiguous DNS alias")
				}
				alias = strings.ToLower(c.Target)
				ttl = min(ttl, h.Ttl)
				continue
			}
			if h.Rrtype != q.Qtype {
				continue
			}
			var ip netip.Addr
			switch a := rr.(type) {
			case *dns.A:
				ip, _ = netip.AddrFromSlice(a.A.To4())
			case *dns.AAAA:
				ip, _ = netip.AddrFromSlice(a.AAAA)
			}
			if !ip.IsValid() || ip.Is4In6() {
				return result{}, errors.New("invalid DNS address family")
			}
			if p.syntheticAddress(ip) {
				return result{}, errors.New("upstream returned a synthetic address")
			}
			if !slices.Contains(r.ips, ip) {
				if len(r.ips) == 32 {
					return result{}, errors.New("too many DNS addresses")
				}
				r.ips = append(r.ips, ip)
			}
			ttl = min(ttl, h.Ttl)
		}
		if alias == "" {
			break
		}
		if len(r.ips) != 0 {
			return result{}, errors.New("DNS alias owner has address records")
		}
		n = alias
	}
	if len(r.ips) != 0 {
		r.until = now.Add(time.Duration(ttl) * time.Second)
	}
	return r, nil
}

type questionKey struct {
	name     string
	typeCode uint16
}

type resolver struct {
	policy   *policy
	writer   *publisher
	upstream func(context.Context, dns.Question) (*dns.Msg, error)
	slots    chan struct{}
	mu       sync.Mutex
	cache    map[questionKey]result
	flights  singleflight.Group
}

func (r *resolver) resolve(ctx context.Context, q dns.Question) (result, error) {
	k := questionKey{strings.ToLower(q.Name), q.Qtype}
	read := func() (result, bool) {
		r.mu.Lock()
		defer r.mu.Unlock()
		v, ok := r.cache[k]
		return v, ok && v.until.After(time.Now())
	}
	if v, ok := read(); ok {
		return v, nil
	}
	v, err, _ := r.flights.Do(k.name+"/"+dns.TypeToString[k.typeCode], func() (any, error) {
		if v, ok := read(); ok {
			return v, nil
		}
		m, err := r.upstream(ctx, q)
		if err != nil {
			return result{}, err
		}
		x, err := inspect(r.policy, q, m, time.Now())
		if err == nil && x.until.After(time.Now()) {
			r.mu.Lock()
			if len(r.cache) >= 2048 {
				clear(r.cache)
			}
			r.cache[k] = x
			r.mu.Unlock()
		}
		return x, err
	})
	return v.(result), err
}

func makeUpstream(addr string) func(context.Context, dns.Question) (*dns.Msg, error) {
	return func(ctx context.Context, q dns.Question) (*dns.Msg, error) {
		m := new(dns.Msg).SetQuestion(q.Name, q.Qtype)
		m.SetEdns0(1232, false)
		c := dns.Client{Net: "udp", UDPSize: 1232, Timeout: 2 * time.Second}
		answer, _, err := c.ExchangeContext(ctx, m, addr)
		if err == nil && answer.Truncated {
			c.Net = "tcp"
			answer, _, err = c.ExchangeContext(ctx, m, addr)
		}
		return answer, err
	}
}

func (r *resolver) reverse(ctx context.Context, q dns.Question, resp *dns.Msg) int {
	name := strings.ToLower(q.Name)
	if !strings.HasSuffix(name, ".in-addr.arpa.") && !strings.HasSuffix(name, ".ip6.arpa.") {
		return dns.RcodeRefused
	}
	m, err := r.upstream(ctx, q)
	if err != nil || ctx.Err() != nil || !matchingReply(q, m) || len(m.Answer) > 16 {
		return dns.RcodeServerFailure
	}
	if m.Rcode != dns.RcodeSuccess {
		if m.Rcode == dns.RcodeNameError {
			return m.Rcode
		}
		return dns.RcodeServerFailure
	}
	for _, rr := range m.Answer {
		ptr, ok := rr.(*dns.PTR)
		if !ok || ptr.Hdr.Class != dns.ClassINET || !strings.EqualFold(ptr.Hdr.Name, name) ||
			!validQuestionName(strings.TrimSuffix(strings.ToLower(ptr.Ptr), ".")) {
			continue
		}
		copy := *ptr
		copy.Hdr.Ttl = min(copy.Hdr.Ttl, maxTTL)
		resp.Answer = append(resp.Answer, &copy)
	}
	return dns.RcodeSuccess
}

func (r *resolver) ServeDNS(w dns.ResponseWriter, req *dns.Msg) {
	resp := new(dns.Msg).SetReply(req)
	resp.RecursionAvailable = true
	resp.AuthenticatedData = false
	write := func(code int) { resp.Rcode = code; _ = w.WriteMsg(resp) }
	if len(req.Question) != 1 || req.Response || req.Truncated || req.Opcode != dns.OpcodeQuery {
		write(dns.RcodeFormatError)
		return
	}
	q := req.Question[0]
	if strings.EqualFold(q.Name, "pkc-native-health.invalid.") && q.Qclass == dns.ClassINET && (q.Qtype == dns.TypeA || q.Qtype == dns.TypeAAAA) {
		write(dns.RcodeSuccess)
		return
	}
	if q.Qclass != dns.ClassINET || !validQuestionName(strings.TrimSuffix(strings.ToLower(q.Name), ".")) {
		write(dns.RcodeRefused)
		return
	}
	switch q.Qtype {
	case dns.TypeHTTPS, dns.TypeSVCB:
		// Do not expose real address hints or alternative targets.
		write(dns.RcodeSuccess)
		return
	case dns.TypeA, dns.TypeAAAA, dns.TypePTR:
	default:
		write(dns.RcodeRefused)
		return
	}
	// A single-stack Native deployment must not advertise an address family
	// for which protected classification cannot publish a synthetic mapping.
	if r.policy.ProtectedUpstream != "" && (q.Qtype == dns.TypeA || q.Qtype == dns.TypeAAAA) && !r.policy.pools[q.Qtype == dns.TypeA].IsValid() {
		write(dns.RcodeSuccess)
		return
	}
	select {
	case r.slots <- struct{}{}:
		defer func() { <-r.slots }()
	default:
		write(dns.RcodeServerFailure)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	fitUDP := func() bool {
		if w.LocalAddr().Network() != "udp" {
			return true
		}
		limit := uint16(512)
		if opt := req.IsEdns0(); opt != nil {
			limit = min(uint16(1232), max(limit, opt.UDPSize()))
		}
		if resp.Len() > int(limit) {
			resp.Truncated = true
			resp.Answer = nil
			return false
		}
		return true
	}
	resp.Compress = true
	if q.Qtype == dns.TypePTR {
		code := r.reverse(ctx, q, resp)
		fitUDP()
		write(code)
		return
	}
	answer, err := r.resolve(ctx, q)
	if err != nil || ctx.Err() != nil {
		write(dns.RcodeServerFailure)
		return
	}
	if len(answer.ips) == 0 {
		write(answer.rcode)
		return
	}
	ttl := uint32(max(int64(0), int64(time.Until(answer.until)/time.Second)))
	appendAddresses := func(ips []netip.Addr) {
		for _, ip := range ips {
			h := dns.RR_Header{Name: q.Name, Rrtype: q.Qtype, Class: q.Qclass, Ttl: ttl}
			if ip.Is4() {
				resp.Answer = append(resp.Answer, &dns.A{Hdr: h, A: net.IP(ip.AsSlice())})
			} else {
				resp.Answer = append(resp.Answer, &dns.AAAA{Hdr: h, AAAA: net.IP(ip.AsSlice())})
			}
		}
	}
	// A truncated UDP reply publishes no binding and carries no addresses.
	appendAddresses(answer.ips)
	if !fitUDP() {
		write(dns.RcodeSuccess)
		return
	}
	// Only an explicit whole-client grant may bypass a protected DNS result.
	// Keep this decision outside the shared cache: another client must still
	// receive a committed synthetic address for the same upstream answer.
	if answer.group >= 0 && !r.policy.directClient(w.RemoteAddr()) {
		resp.Answer = nil
		fake, err := r.writer.publishName(ctx, answer.group, answer.ips, ttl, q.Name)
		if err != nil || ctx.Err() != nil {
			write(dns.RcodeServerFailure)
			return
		}
		ttl = uint32(max(int64(0), int64(time.Until(answer.until)/time.Second)))
		appendAddresses(fake)
	}
	write(dns.RcodeSuccess)
}
