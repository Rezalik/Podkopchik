package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"net"
	"net/http"
	"os"
	"testing"
	"time"

	"github.com/miekg/dns"
)

func TestProtectedDNSBoundServer(t *testing.T) {
	if os.Getenv("PKC_DNS_BOUND_SERVER") != "1" {
		t.Skip("isolated VM fixture only")
	}
	cert, _ := httpsCertificate(t)
	path := os.Getenv("PKC_DNS_BOUND_CERT")
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert.Certificate[0]}), 0600); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp4", "1.1.1.1:443")
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{ReadHeaderTimeout: 2 * time.Second, Handler: http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		wire, _ := wireAnswer(t, req).Pack()
		w.Header().Set("Content-Type", "application/dns-message")
		_, _ = w.Write(wire)
	})}
	if err := os.WriteFile(path+".ready", []byte("ready"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Fatal(server.Serve(tls.NewListener(listener, &tls.Config{Certificates: []tls.Certificate{cert}})))
}

func TestProtectedDNSBoundHTTPSFallback(t *testing.T) {
	if os.Getenv("PKC_DNS_BOUND_CLIENT") != "1" {
		t.Skip("isolated VM fixture only")
	}
	cert, err := os.ReadFile(os.Getenv("PKC_DNS_BOUND_CERT"))
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(cert) {
		t.Fatal("missing fixture root")
	}
	iface, err := net.InterfaceByName("paw111111111111")
	if err != nil {
		t.Fatal(err)
	}
	s := protectedDNSState{Schema: 1,
		Endpoints: []dnsEndpoint{{Address: "1.1.1.1:853", Name: "one.one.one.one"}},
		Transports: []dnsTransport{{Tag: "fixture", Type: "amneziawg", Interface: iface.Name, Index: iface.Index,
			Mark: 536912912, IPv4: true}},
	}
	path := t.TempDir() + "/dns-state.json"
	write := func() {
		b, _ := json.Marshal(s)
		if err := os.WriteFile(path, b, 0600); err != nil {
			t.Fatal(err)
		}
	}
	write()
	r := newProtectedResolver(path)
	r.tlsConfig = &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}
	q := dns.Question{Name: "www.youtube.com.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	before, _ := os.ReadDir("/proc/self/fd")
	for i := 0; i < 20; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
		m, err := r.query(ctx, q)
		cancel()
		if err != nil || len(m.Answer) != 1 {
			t.Fatal("bound HTTPS fallback failed", err)
		}
	}
	after, _ := os.ReadDir("/proc/self/fd")
	if len(after) > len(before)+4 {
		t.Fatalf("HTTPS FD accumulation: %d -> %d", len(before), len(after))
	}
	s.Transports[0].Index++
	write()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if _, err := r.query(ctx, q); err == nil {
		t.Fatal("stale binding permitted a query")
	}
	s.Transports = nil
	write()
	if _, err := r.query(ctx, q); err == nil {
		t.Fatal("all-down permitted a query")
	}
	t.Logf("same-tunnel HTTPS survived blocked DoT; fd %d -> %d; stale binding and all-down refused", len(before), len(after))
}
