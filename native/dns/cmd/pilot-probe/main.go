// pilot-probe is a temporary acceptance tool, not a router service.
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"os"
	"strconv"
	"time"

	quic "github.com/apernet/quic-go"
	"github.com/apernet/quic-go/http3"
	"github.com/miekg/dns"
)

func run(args []string) error {
	if len(args) < 2 {
		return errors.New("use lookup, tcp, udp-echo, udp-serve or quic with a numeric IPv4 endpoint")
	}
	mode := args[0]
	endpoint, err := netip.ParseAddrPort(args[1])
	if err != nil || !endpoint.Addr().Is4() || endpoint.Port() == 0 {
		return errors.New("invalid IPv4 endpoint")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	switch mode {
	case "lookup":
		if len(args) != 4 || (args[2] != "tcp" && args[2] != "udp") {
			return errors.New("lookup requires TCP/UDP and a hostname")
		}
		q := new(dns.Msg).SetQuestion(dns.Fqdn(args[3]), dns.TypeA)
		c := &dns.Client{Net: args[2], Timeout: 4 * time.Second}
		m, _, err := c.ExchangeContext(ctx, q, endpoint.String())
		if err != nil {
			return err
		}
		if m.Rcode != dns.RcodeSuccess || len(m.Answer) != 1 {
			return errors.New("DNS did not return exactly one answer")
		}
		if a, ok := m.Answer[0].(*dns.A); ok {
			fmt.Println(a.A)
			return nil
		}
		return errors.New("expected A answer")
	case "tcp":
		if len(args) != 2 {
			return errors.New("tcp requires one endpoint")
		}
		d := net.Dialer{Timeout: 2 * time.Second}
		c, err := d.DialContext(ctx, "tcp4", endpoint.String())
		if err != nil {
			return err
		}
		c.Close()
		fmt.Println("TCP connection established")
	case "udp-echo":
		if len(args) > 3 {
			return errors.New("udp-echo requires an endpoint and an optional Linux interface")
		}
		iface := ""
		if len(args) == 3 {
			iface = args[2]
		}
		return probeEcho(ctx, endpoint, iface)
	case "udp-serve":
		if len(args) != 3 {
			return errors.New("udp-serve requires a bind endpoint and a lifetime in seconds")
		}
		seconds, err := strconv.Atoi(args[2])
		if err != nil || seconds < 1 || seconds > 600 || endpoint.Addr().IsUnspecified() {
			return errors.New("use a specific bind address and a lifetime of 1 to 600 seconds")
		}
		return serveEcho(endpoint, time.Duration(seconds)*time.Second)
	case "quic":
		if len(args) != 3 || endpoint.Port() != 443 {
			return errors.New("quic requires UDP/443 and a TLS server name")
		}
		if labels, ok := dns.IsDomainName(args[2]); !ok || labels < 2 {
			return errors.New("invalid QUIC TLS server name")
		}
		tr := &http3.Transport{
			TLSClientConfig: &tls.Config{ServerName: args[2], MinVersion: tls.VersionTLS13},
			Dial: func(ctx context.Context, _ string, tlsCfg *tls.Config, cfg *quic.Config) (*quic.Conn, error) {
				return quic.DialAddr(ctx, endpoint.String(), tlsCfg, cfg)
			},
		}
		defer tr.Close()
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://"+args[2]+"/", nil)
		if err != nil {
			return err
		}
		res, err := tr.RoundTrip(req)
		if err != nil {
			return err
		}
		defer res.Body.Close()
		if res.ProtoMajor != 3 || res.StatusCode < 200 || res.StatusCode >= 400 {
			return errors.New("expected a successful HTTP/3 response")
		}
		fmt.Printf("HTTP/3 response verified: %d\n", res.StatusCode)
	default:
		return errors.New("unknown probe")
	}
	return nil
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
