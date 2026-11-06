package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"math/big"
	"os"
	"time"

	quic "github.com/apernet/quic-go"
)

// Both sides run only in the isolated guest; private keys never leave memory.
func quicFixture(mode, addr, certPath string) error {
	tlsConf := &tls.Config{NextProtos: []string{"podkopchik-lab"}, ServerName: "protected.example"}
	if mode == "quic-serve" {
		pub, key, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			return err
		}
		now := time.Now()
		leaf := &x509.Certificate{SerialNumber: big.NewInt(1), DNSNames: []string{tlsConf.ServerName}, NotBefore: now.Add(-time.Minute),
			NotAfter: now.Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
		der, err := x509.CreateCertificate(rand.Reader, leaf, leaf, pub, key)
		if err != nil {
			return err
		}
		tlsConf.Certificates = []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}
		listener, err := quic.ListenAddr(addr, tlsConf, nil)
		if err != nil {
			return err
		}
		defer listener.Close()
		if err := os.WriteFile(certPath, der, 0600); err != nil {
			return err
		}
		for {
			c, err := listener.Accept(context.Background())
			if err != nil {
				return err
			}
			go func() {
				ctx, cancel := context.WithTimeout(c.Context(), 3*time.Second)
				defer cancel()
				s, err := c.AcceptStream(ctx)
				if err == nil {
					_ = s.SetDeadline(time.Now().Add(2 * time.Second))
					if b, err := io.ReadAll(io.LimitReader(s, 32)); err == nil && string(b) == "request" {
						_, _ = s.Write([]byte("quic-ok"))
					}
					_ = s.Close()
				}
			}()
		}
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
	c, err := quic.DialAddr(ctx, addr, tlsConf, nil)
	if err != nil {
		return err
	}
	defer c.CloseWithError(0, "")
	s, err := c.OpenStreamSync(ctx)
	if err != nil {
		return err
	}
	_ = s.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err := s.Write([]byte("request")); err != nil {
		return err
	}
	if err := s.Close(); err != nil {
		return err
	}
	if b, err := io.ReadAll(io.LimitReader(s, 32)); err != nil || string(b) != "quic-ok" {
		return errors.New("QUIC response missing")
	}
	return nil
}
