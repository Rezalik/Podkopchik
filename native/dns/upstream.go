package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/miekg/dns"
	"golang.org/x/net/proxy"
	"golang.org/x/sys/unix"
)

type dnsEndpoint struct {
	Address string `json:"address"`
	Name    string `json:"name"`
}
type dnsTransport struct {
	Tag       string `json:"tag"`
	Type      string `json:"type"`
	Interface string `json:"interface,omitempty"`
	Index     int    `json:"index,omitempty"`
	Mark      int    `json:"mark,omitempty"`
	Socks     string `json:"socks,omitempty"`
	IPv4      bool   `json:"ipv4"`
	IPv6      bool   `json:"ipv6"`
}
type protectedDNSState struct {
	Schema     int            `json:"schema"`
	Endpoints  []dnsEndpoint  `json:"endpoints"`
	Transports []dnsTransport `json:"transports"`
}

var dnsIfaceRE = regexp.MustCompile(`^paw[a-f0-9]{12}$`)

func readProtectedState(path string) (protectedDNSState, error) {
	var s protectedDNSState
	f, err := privateOpen(path, unix.O_RDONLY)
	if err != nil {
		return s, errors.New("protected DNS transport state unavailable")
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() || st.Size() > 32768 {
		return s, errors.New("invalid protected DNS state")
	}
	d := json.NewDecoder(f)
	d.DisallowUnknownFields()
	if d.Decode(&s) != nil || d.Decode(new(any)) != io.EOF || s.Schema != 1 || len(s.Endpoints) < 1 || len(s.Endpoints) > 8 || len(s.Transports) > 4 {
		return s, errors.New("invalid protected DNS state")
	}
	for _, e := range s.Endpoints {
		a, err := netip.ParseAddrPort(e.Address)
		if err != nil || a.Port() == 0 || a.Addr().Zone() != "" || a.Addr().Is4In6() || a.Addr().IsUnspecified() || a.Addr().IsMulticast() || !validName(e.Name) {
			return s, errors.New("invalid pinned TLS DNS endpoint")
		}
	}
	for _, t := range s.Transports {
		if !labelRE.MatchString(strings.ReplaceAll(t.Tag, "_", "-")) || len(t.Tag) > 64 || (!t.IPv4 && !t.IPv6) {
			return s, errors.New("invalid protected DNS transport")
		}
		switch t.Type {
		case "amneziawg":
			if !dnsIfaceRE.MatchString(t.Interface) || t.Index < 1 || t.Mark < 0x20000000 || t.Mark >= 0x20010000 || t.Socks != "" {
				return s, errors.New("invalid DNS tunnel binding")
			}
		case "vless":
			a, err := netip.ParseAddrPort(t.Socks)
			if err != nil || !a.Addr().IsLoopback() || a.Port() < 23032 || a.Port() > 23063 || t.Interface != "" || t.Mark != 0 || t.Index != 0 {
				return s, errors.New("invalid DNS proxy binding")
			}
		default:
			return s, errors.New("unprotected DNS transport refused")
		}
	}
	return s, nil
}

type protectedResolver struct {
	path   string
	mu     sync.Mutex
	failed map[string]time.Time
	// Replaced only by unit fixtures, never configurable on a router.
	dial      func(context.Context, dnsTransport, string) (net.Conn, error)
	tlsConfig *tls.Config
}

func newProtectedResolver(path string) *protectedResolver {
	return &protectedResolver{path: path, failed: map[string]time.Time{}, dial: protectedDial}
}
func protectedDial(ctx context.Context, t dnsTransport, address string) (net.Conn, error) {
	d := &net.Dialer{}
	if t.Type == "amneziawg" {
		if err := bindDNSDevice(d, t); err != nil {
			return nil, err
		}
		return d.DialContext(ctx, "tcp", address)
	}
	s, err := proxy.SOCKS5("tcp", t.Socks, nil, d)
	if err != nil {
		return nil, err
	}
	c, ok := s.(proxy.ContextDialer)
	if !ok {
		return nil, errors.New("bounded proxy DNS dial unavailable")
	}
	return c.DialContext(ctx, "tcp", address)
}
func (r *protectedResolver) exchange(ctx context.Context, t dnsTransport, e dnsEndpoint, q dns.Question) (*dns.Msg, error) {
	c, err := r.dial(ctx, t, e.Address)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	if deadline, ok := ctx.Deadline(); ok {
		_ = c.SetDeadline(deadline)
	}
	cfg := &tls.Config{MinVersion: tls.VersionTLS12, ServerName: e.Name}
	if r.tlsConfig != nil {
		cfg = r.tlsConfig.Clone()
		cfg.ServerName = e.Name
	}
	secure := tls.Client(c, cfg)
	if err := secure.HandshakeContext(ctx); err != nil {
		return nil, err
	}
	conn := &dns.Conn{Conn: secure}
	request := new(dns.Msg).SetQuestion(q.Name, q.Qtype)
	request.SetEdns0(1232, false)
	if err := conn.WriteMsg(request); err != nil {
		return nil, err
	}
	answer, err := conn.ReadMsg()
	if err != nil || answer.Id != request.Id || !matchingReply(q, answer) || (answer.Rcode != dns.RcodeSuccess && answer.Rcode != dns.RcodeNameError) {
		return nil, errors.New("invalid protected DNS reply")
	}
	return answer, nil
}
func (r *protectedResolver) query(ctx context.Context, q dns.Question) (*dns.Msg, error) {
	s, err := readProtectedState(r.path)
	if err != nil {
		return nil, err
	}
	for _, t := range s.Transports {
		for _, e := range s.Endpoints {
			addr := netip.MustParseAddrPort(e.Address).Addr()
			if (addr.Is4() && !t.IPv4) || (addr.Is6() && !t.IPv6) {
				continue
			}
			key := fmt.Sprintf("%s/%s/%d/%d/%s/%s/%s", t.Tag, t.Interface, t.Index, t.Mark, t.Socks, e.Address, e.Name)
			r.mu.Lock()
			until := r.failed[key]
			r.mu.Unlock()
			if time.Now().Before(until) {
				continue
			}
			attempt, stop := context.WithTimeout(ctx, 1500*time.Millisecond)
			answer, err := r.exchange(attempt, t, e, q)
			stop()
			if err == nil {
				return answer, nil
			}
			r.mu.Lock()
			if len(r.failed) >= 128 {
				clear(r.failed)
			}
			// Longer than one complete query budget: retries can reach later
			// healthy transports instead of repeatedly exhausting it on the first.
			r.failed[key] = time.Now().Add(5 * time.Second)
			r.mu.Unlock()
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
		}
	}
	return nil, errors.New("protected DNS upstream unavailable; no direct fallback")
}

func protectedProbe(path, name string) error {
	if !validName(name) {
		return errors.New("invalid DNS probe name")
	}
	ctx, stop := context.WithTimeout(context.Background(), 5*time.Second)
	defer stop()
	m, err := newProtectedResolver(path).query(ctx, dns.Question{Name: dns.Fqdn(name), Qtype: dns.TypeA, Qclass: dns.ClassINET})
	if err != nil {
		return err
	}
	var ips []string
	for _, rr := range m.Answer {
		if a, ok := rr.(*dns.A); ok {
			ips = append(ips, a.A.String())
		}
	}
	if len(ips) == 0 {
		return errors.New("protected DNS probe has no A answer")
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{"protected_dns": true, "addresses": ips})
}
