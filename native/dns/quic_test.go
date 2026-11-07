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
	"os"
	"time"

	quic "github.com/apernet/quic-go"
	"github.com/apernet/quic-go/http3"
)

// Both sides run only in the isolated guest; private keys never leave memory.
func quicFixture(mode, addr, certPath string) error {
	tlsConf := &tls.Config{ServerName: "protected.example", MinVersion: tls.VersionTLS13}
	if mode == "quic-serve" || mode == "https-serve" {
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return err
		}
		now := time.Now()
		leaf := &x509.Certificate{SerialNumber: big.NewInt(1), DNSNames: []string{tlsConf.ServerName}, NotBefore: now.Add(-time.Minute),
			NotAfter: now.Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
		der, err := x509.CreateCertificate(rand.Reader, leaf, leaf, &key.PublicKey, key)
		if err != nil {
			return err
		}
		tlsConf.Certificates = []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}
		if err := os.WriteFile(certPath, der, 0600); err != nil {
			return err
		}
		handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/test" || (mode == "quic-serve" && r.ProtoMajor != 3) {
				http.NotFound(w, r)
				return
			}
			_, _ = w.Write([]byte("tls-ok"))
		})
		if mode == "https-serve" {
			server := http.Server{Addr: addr, TLSConfig: tlsConf, Handler: handler, ReadHeaderTimeout: time.Second}
			return server.ListenAndServeTLS("", "")
		}
		server := http3.Server{Addr: addr, TLSConfig: tlsConf, Handler: handler}
		return server.ListenAndServe()
	}
	der, err := os.ReadFile(certPath)
	if err != nil {
		return err
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		return err
	}
	tlsConf.RootCAs = x509.NewCertPool()
	tlsConf.RootCAs.AddCert(cert)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	transport := &http3.Transport{TLSClientConfig: tlsConf,
		Dial: func(ctx context.Context, _ string, tlsCfg *tls.Config, cfg *quic.Config) (*quic.Conn, error) {
			return quic.DialAddr(ctx, addr, tlsCfg, cfg)
		}}
	defer transport.Close()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://protected.example/test", nil)
	if err != nil {
		return err
	}
	var res *http.Response
	proto := 3
	if mode == "https-client" {
		proto = 1
		dialer := &net.Dialer{}
		tcp := &http.Transport{TLSClientConfig: tlsConf,
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return dialer.DialContext(ctx, "tcp", addr)
			}}
		defer tcp.CloseIdleConnections()
		res, err = tcp.RoundTrip(req)
	} else {
		res, err = transport.RoundTrip(req)
	}
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if b, err := io.ReadAll(io.LimitReader(res.Body, 32)); err != nil || res.ProtoMajor != proto || res.StatusCode != 200 || string(b) != "tls-ok" {
		return errors.New("TLS HTTP response missing")
	}
	return nil
}
