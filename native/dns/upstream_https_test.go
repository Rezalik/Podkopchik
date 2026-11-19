package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/miekg/dns"
)

func httpsCertificate(t *testing.T) (tls.Certificate, *tls.Config) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	leaf := &x509.Certificate{SerialNumber: big.NewInt(1),
		DNSNames:  []string{"cloudflare-dns.com", "dns.quad9.net"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, leaf, leaf, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(cert)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: roots}
}

func wireAnswer(t *testing.T, req *http.Request) *dns.Msg {
	t.Helper()
	if req.Method != "POST" || req.URL.Path != "/dns-query" || req.URL.RawQuery != "" ||
		req.Header.Get("Content-Type") != "application/dns-message" ||
		req.Header.Get("Accept") != "application/dns-message" || req.Header.Get("Cache-Control") != "no-store" {
		t.Error("unexpected protected DNS HTTPS request")
	}
	body, err := io.ReadAll(io.LimitReader(req.Body, 65536))
	if err != nil {
		t.Error(err)
		return new(dns.Msg)
	}
	query := new(dns.Msg)
	if err := query.Unpack(body); err != nil {
		t.Error(err)
	}
	answer := new(dns.Msg).SetReply(query)
	answer.Answer = []dns.RR{&dns.A{Hdr: dns.RR_Header{Name: query.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 60}, A: net.ParseIP("203.0.113.80")}}
	return answer
}

func httpsFixture(t *testing.T, handler http.Handler) (string, *tls.Config) {
	t.Helper()
	cert, roots := httpsCertificate(t)
	server := httptest.NewUnstartedServer(handler)
	server.TLS = &tls.Config{Certificates: []tls.Certificate{cert}}
	server.StartTLS()
	t.Cleanup(server.Close)
	return server.Listener.Addr().String(), roots
}

func TestProtectedDNSHTTPSFallbackThroughSameTransport(t *testing.T) {
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:1")
	t.Setenv("HTTP_PROXY", "http://127.0.0.1:1")
	var replies atomic.Int32
	addr, roots := httpsFixture(t, http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		replies.Add(1)
		answer, _ := wireAnswer(t, req).Pack()
		w.Header().Set("Content-Type", "application/dns-message")
		_, _ = w.Write(answer)
	}))
	r, s, _, write := protectedFixture(t)
	s.Endpoints = []dnsEndpoint{{Address: "1.1.1.1:853", Name: "one.one.one.one"}}
	write()
	r.tlsConfig = roots
	original := s.Transports[0]
	var dot, doh atomic.Int32
	r.dial = func(ctx context.Context, tr dnsTransport, target string) (net.Conn, error) {
		if tr != original {
			t.Error("HTTPS changed the protected transport")
			return nil, errors.New("transport changed")
		}
		if target == "1.1.1.1:853" {
			dot.Add(1)
			return nil, errors.New("blocked DoT")
		}
		if target != "1.1.1.1:443" {
			t.Error("unpinned fallback dial")
			return nil, errors.New("unexpected dial")
		}
		doh.Add(1)
		return (&net.Dialer{}).DialContext(ctx, "tcp", addr)
	}
	q := dns.Question{Name: "www.youtube.com.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	for i := 0; i < 2; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		m, err := r.query(ctx, q)
		cancel()
		if err != nil || len(m.Answer) != 1 {
			t.Fatal("same-tunnel HTTPS fallback failed", err)
		}
	}
	if dot.Load() != 1 || doh.Load() != 2 || replies.Load() != 2 {
		t.Fatal("DoT backoff or HTTPS resource reuse changed", dot.Load(), doh.Load(), replies.Load())
	}
	s.Transports = nil
	write()
	if _, err := r.query(context.Background(), q); err == nil || replies.Load() != 2 {
		t.Fatal("all-down used an unprotected resolver")
	}
}

func TestProtectedDNSHTTPSProviderScope(t *testing.T) {
	for _, e := range []dnsEndpoint{
		{Address: "1.1.1.1:853", Name: "one.one.one.one"},
		{Address: "[2606:4700:4700::1111]:853", Name: "one.one.one.one"},
		{Address: "9.9.9.9:853", Name: "dns.quad9.net"},
		{Address: "[2620:fe::fe]:853", Name: "dns.quad9.net"},
	} {
		next, ok := httpsFallback(e)
		host, port, err := net.SplitHostPort(next.Address)
		if !ok || err != nil || port != "443" || net.ParseIP(host) == nil {
			t.Fatal("known encrypted provider has no pinned HTTPS alternate", e)
		}
	}
	for _, e := range []dnsEndpoint{
		{Address: "1.1.1.1:853", Name: "custom.example"},
		{Address: "203.0.113.80:853", Name: "one.one.one.one"},
		{Address: "9.9.9.9:8853", Name: "dns.quad9.net"},
		{Address: "resolver.example:853", Name: "one.one.one.one"},
	} {
		if _, ok := httpsFallback(e); ok {
			t.Fatal("custom provider silently changed", e)
		}
	}
}

func TestProtectedDNSHTTPSResponseAndTLSValidation(t *testing.T) {
	for _, kind := range []string{"ok", "redirect", "media", "oversized", "question", "id", "rcode", "malformed", "certificate"} {
		t.Run(kind, func(t *testing.T) {
			var count atomic.Int32
			addr, roots := httpsFixture(t, http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				count.Add(1)
				answer := wireAnswer(t, req)
				w.Header().Set("Content-Type", "application/dns-message")
				switch kind {
				case "redirect":
					w.Header().Set("Location", "https://untrusted.invalid/dns-query")
					w.WriteHeader(302)
					return
				case "media":
					w.Header().Set("Content-Type", "text/html")
				case "oversized":
					_, _ = w.Write(make([]byte, 65536))
					return
				case "question":
					answer.Question[0].Name = "wrong.example."
				case "id":
					answer.Id++
				case "rcode":
					answer.Rcode = dns.RcodeServerFailure
				case "malformed":
					_, _ = w.Write([]byte("not DNS"))
					return
				}
				wire, _ := answer.Pack()
				_, _ = w.Write(wire)
			}))
			r := &protectedResolver{tlsConfig: roots, dial: func(ctx context.Context, _ dnsTransport, _ string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "tcp", addr)
			}}
			if kind == "certificate" {
				r.tlsConfig = &tls.Config{RootCAs: x509.NewCertPool(), MinVersion: tls.VersionTLS12}
			}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			_, err := r.exchangeHTTPS(ctx, dnsTransport{}, dnsEndpoint{Address: "1.1.1.1:443", Name: "cloudflare-dns.com"},
				dns.Question{Name: "www.youtube.com.", Qtype: dns.TypeA, Qclass: dns.ClassINET})
			if kind == "ok" && err != nil || kind != "ok" && err == nil {
				t.Fatalf("%s response result: %v", kind, err)
			}
			if kind == "certificate" && count.Load() != 0 {
				t.Fatal("invalid certificate reached HTTP")
			}
			if count.Load() > 1 {
				t.Fatal("redirect was followed")
			}
		})
	}
}

func TestProtectedDNSHTTPSBoundedCancellation(t *testing.T) {
	r := &protectedResolver{dial: func(ctx context.Context, _ dnsTransport, _ string) (net.Conn, error) {
		<-ctx.Done()
		return nil, ctx.Err()
	}}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	start := time.Now()
	if _, err := r.exchangeHTTPS(ctx, dnsTransport{}, dnsEndpoint{Address: "1.1.1.1:443", Name: "cloudflare-dns.com"},
		dns.Question{Name: "www.youtube.com.", Qtype: dns.TypeA, Qclass: dns.ClassINET}); err == nil {
		t.Fatal("unresponsive HTTPS provider accepted")
	}
	if time.Since(start) > time.Second {
		t.Fatal("HTTPS ignored its query deadline")
	}
}
