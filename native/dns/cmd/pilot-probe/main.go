// pilot-probe is a temporary acceptance tool, not a router service.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"time"

	quic "github.com/apernet/quic-go"
	"github.com/miekg/dns"
)

func run(args []string) error {
	if len(args) < 2 {
		return errors.New("use lookup, tcp, ntp or quic with a numeric IPv4 endpoint")
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
	case "ntp":
		if len(args) != 2 || endpoint.Port() != 123 {
			return errors.New("ntp requires a UDP/123 endpoint")
		}
		d := net.Dialer{}
		c, err := d.DialContext(ctx, "udp4", endpoint.String())
		if err != nil {
			return err
		}
		defer c.Close()
		deadline, _ := ctx.Deadline()
		if err := c.SetDeadline(deadline); err != nil {
			return err
		}
		var request [48]byte
		request[0] = 0x23 // NTPv4 client.
		binary.BigEndian.PutUint32(request[40:44], uint32(time.Now().Unix()+2208988800))
		if _, err := rand.Read(request[44:]); err != nil {
			return err
		}
		if _, err := c.Write(request[:]); err != nil {
			return err
		}
		var reply [512]byte
		n, err := c.Read(reply[:])
		if err != nil {
			return err
		}
		if n < 48 || reply[0]&7 != 4 || reply[1] == 0 || !bytes.Equal(reply[24:32], request[40:48]) {
			return errors.New("NTP response did not match the probe")
		}
		fmt.Println("UDP NTP response verified; system clock unchanged")
	case "quic":
		if len(args) != 3 || endpoint.Port() != 443 {
			return errors.New("quic requires UDP/443 and a TLS server name")
		}
		if labels, ok := dns.IsDomainName(args[2]); !ok || labels < 2 {
			return errors.New("invalid QUIC TLS server name")
		}
		c, err := quic.DialAddr(ctx, endpoint.String(), &tls.Config{
			ServerName: args[2], NextProtos: []string{"h3"}, MinVersion: tls.VersionTLS13,
		}, nil)
		if err != nil {
			return err
		}
		defer c.CloseWithError(0, "pilot done")
		s := c.ConnectionState().TLS
		if s.NegotiatedProtocol != "h3" || len(s.VerifiedChains) == 0 {
			return errors.New("QUIC did not authenticate an h3 peer")
		}
		fmt.Println("QUIC TLS handshake verified; ALPN h3")
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
