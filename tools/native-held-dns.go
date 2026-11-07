//go:build darwin

// Workstation-only acceptance: retain one UDP socket across the LAN cutover.
package main

import (
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
	"os"
	"syscall"
	"time"

	"github.com/miekg/dns"
	"golang.org/x/sys/unix"
)

func run() error {
	if len(os.Args) != 7 {
		return fmt.Errorf("endpoint interface name marker-prefix old-pool new-pool required")
	}
	i, err := net.InterfaceByName(os.Args[2])
	if err != nil { return err }
	d := &net.Dialer{Control: func(_, _ string, raw syscall.RawConn) error {
		var e error
		if err := raw.Control(func(fd uintptr) { e = unix.SetsockoptInt(int(fd), unix.IPPROTO_IP, unix.IP_BOUND_IF, i.Index) }); err != nil { return err }
		return e
	}}
	c, err := d.Dial("udp4", os.Args[1])
	if err != nil { return err }
	defer c.Close()
	wire := &dns.Conn{Conn:c}
	check := func(pool string) error {
		prefix, err := netip.ParsePrefix(pool)
		if err != nil { return err }
		_ = c.SetDeadline(time.Now().Add(4*time.Second))
		q := new(dns.Msg).SetQuestion(dns.Fqdn(os.Args[3]), dns.TypeA)
		q.SetEdns0(1232, false)
		if err := wire.WriteMsg(q); err != nil { return err }
		m, err := wire.ReadMsg()
		if err != nil { return err }
		if m.Id != q.Id || m.Truncated || m.Rcode != dns.RcodeSuccess || len(m.Answer)==0 { return fmt.Errorf("invalid held DNS reply") }
		for _, rr := range m.Answer {
			a, ok := rr.(*dns.A)
			if !ok { return fmt.Errorf("held DNS expected address only") }
			ip, ok := netip.AddrFromSlice(a.A.To4())
			if !ok || !prefix.Contains(ip) { return fmt.Errorf("held DNS reply outside expected pool %s", pool) }
		}
		return nil
	}
	write := func(suffix string, value any) error {
		b, err := json.Marshal(value)
		if err != nil { return err }
		return os.WriteFile(os.Args[4]+suffix, append(b,'\n'),0600)
	}
	if err := check(os.Args[5]); err != nil { return err }
	port := c.LocalAddr().(*net.UDPAddr).Port
	if err := write(".ready", map[string]any{"legacy_query":true,"source_port":port}); err != nil { return err }
	end := time.Now().Add(180*time.Second)
	for {
		if _, err := os.Stat(os.Args[4]+".continue"); err==nil { break }
		if time.Now().After(end) { return fmt.Errorf("held DNS cutover deadline expired") }
		time.Sleep(100*time.Millisecond)
	}
	if err := check(os.Args[6]); err != nil { return err }
	if err := write(".result", map[string]any{"same_udp_socket":true,"legacy_to_native":true,"source_port":port}); err != nil { return err }
	fmt.Println("PASS: one held LAN DNS UDP socket survived legacy-to-Native cutover")
	return nil
}
func main() { if err:=run(); err!=nil { fmt.Fprintln(os.Stderr,err);os.Exit(1) } }
