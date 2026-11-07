package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"math/big"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/miekg/dns"
)

func dotFixture(t *testing.T) (string, *tls.Config, *atomic.Int32) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	c := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "resolver.example"}, DNSNames: []string{"resolver.example"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, c, c, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(cert)
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var count atomic.Int32
	srv := &dns.Server{Listener: tls.NewListener(ln, &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}}), Handler: dns.HandlerFunc(func(w dns.ResponseWriter, m *dns.Msg) {
		count.Add(1)
		r := new(dns.Msg).SetReply(m)
		r.Answer = []dns.RR{&dns.A{Hdr: dns.RR_Header{Name: m.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 60}, A: net.ParseIP("203.0.113.80")}}
		_ = w.WriteMsg(r)
	})}
	go srv.ActivateAndServe()
	t.Cleanup(func() { _ = srv.Shutdown(); _ = ln.Close() })
	return ln.Addr().String(), &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}, &count
}
func protectedFixture(t *testing.T) (*protectedResolver, *protectedDNSState, *atomic.Int32, func()) {
	addr, cfg, count := dotFixture(t)
	s := &protectedDNSState{Schema: 1, Endpoints: []dnsEndpoint{{Address: addr, Name: "resolver.example"}}, Transports: []dnsTransport{{Tag: "awg_11111111111111111111111111111111", Type: "amneziawg", Interface: "paw111111111111", Index: 1, Mark: 536913185, IPv4: true}}}
	path := t.TempDir() + "/state.json"
	write := func() {
		b, _ := json.Marshal(s)
		if err := os.WriteFile(path, b, 0600); err != nil {
			t.Fatal(err)
		}
	}
	write()
	r := newProtectedResolver(path)
	r.tlsConfig = cfg
	r.dial = func(ctx context.Context, tr dnsTransport, address string) (net.Conn, error) {
		if tr.Type != "amneziawg" || tr.Mark == 0 {
			t.Error("unbound transport dial")
		}
		return (&net.Dialer{}).DialContext(ctx, "tcp", address)
	}
	return r, s, count, write
}
func TestProtectedDNSNoSystemOrDirectFallback(t *testing.T) {
	r, s, count, write := protectedFixture(t)
	q := dns.Question{Name: "www.youtube.com.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	ctx, stop := context.WithTimeout(context.Background(), time.Second*3)
	defer stop()
	if m, e := r.query(ctx, q); e != nil || len(m.Answer) != 1 {
		t.Fatal("TLS query", e)
	}
	s.Transports = nil
	write()
	if _, e := r.query(ctx, q); e == nil {
		t.Fatal("all-down allowed DNS")
	}
	if count.Load() != 1 {
		t.Fatal("all-down contacted upstream")
	}
	s.Transports = []dnsTransport{{Tag: "direct", Type: "direct", IPv4: true}}
	write()
	if _, e := r.query(ctx, q); e == nil {
		t.Fatal("accepted direct DNS transport")
	}
	if count.Load() != 1 {
		t.Fatal("unprotected DNS contacted upstream")
	}
}
func TestProtectedDNSTLSVerificationFallbackAndRecovery(t *testing.T) {
	r, s, count, write := protectedFixture(t)
	q := dns.Question{Name: "www.youtube.com.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	good := s.Endpoints[0]
	s.Endpoints = []dnsEndpoint{{Address: good.Address, Name: "wrong.example"}, good}
	write()
	ctx, stop := context.WithTimeout(context.Background(), 3*time.Second)
	defer stop()
	if _, e := r.query(ctx, q); e != nil {
		t.Fatal("TLS-verified backup failed", e)
	}
	if count.Load() != 1 {
		t.Fatal("invalid certificate was accepted")
	}
	s.Endpoints = s.Endpoints[:1]
	write()
	if _, e := r.query(ctx, q); e == nil {
		t.Fatal("all providers failed without SERVFAIL")
	}
	s.Endpoints = []dnsEndpoint{good}
	write()
	if _, e := r.query(ctx, q); e != nil {
		t.Fatal("upstream recovery required restart", e)
	}
}
func TestProtectedDNSConcurrentQueriesAndPrivateState(t *testing.T) {
	r, _, count, _ := protectedFixture(t)
	var wg sync.WaitGroup
	for i := 0; i < 40; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ctx, stop := context.WithTimeout(context.Background(), 3*time.Second)
			defer stop()
			if _, err := r.query(ctx, dns.Question{Name: "protected.example.", Qtype: dns.TypeA, Qclass: dns.ClassINET}); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if count.Load() != 40 {
		t.Fatal("lost concurrent request")
	}
	if err := os.Chmod(r.path, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := r.query(context.Background(), dns.Question{Name: "protected.example.", Qtype: dns.TypeA, Qclass: dns.ClassINET}); err == nil {
		t.Fatal("accepted public transport state")
	}
}

func TestProtectedDNSLaterTransportIsNotStarved(t *testing.T) {
	r, s, count, write := protectedFixture(t)
	s.Endpoints = append(s.Endpoints, dnsEndpoint{Address: "127.0.0.2:853", Name: "resolver.example"})
	base := s.Transports[0]
	for _, id := range []string{"22222222222222222222222222222222", "33333333333333333333333333333333"} {
		x := base
		x.Tag = "awg_" + id
		s.Transports = append(s.Transports, x)
	}
	write()
	dial := r.dial
	r.dial = func(ctx context.Context, tr dnsTransport, address string) (net.Conn, error) {
		if tr.Tag != s.Transports[2].Tag {
			<-ctx.Done()
			return nil, ctx.Err()
		}
		return dial(ctx, tr, address)
	}
	q := dns.Question{Name: "protected.example.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	first, stop := context.WithTimeout(context.Background(), 5*time.Second)
	if _, err := r.query(first, q); err == nil {
		t.Fatal("unresponsive transports did not consume the first bounded query")
	}
	stop()
	retry, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, err := r.query(retry, q); err != nil || count.Load() != 1 {
		t.Fatal("later healthy transport was starved on retry", err, count.Load())
	}
}
