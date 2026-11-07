package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"time"

	"github.com/miekg/dns"
	"golang.org/x/sys/unix"
)

func run() error {
	conf := flag.String("config", "", "compiled DNS policy JSON")
	state := flag.String("ledger", "", "private generation watermark file")
	initLedger := flag.Bool("init-ledger", false, "initialize a NEW generation once; do not start listener")
	check := flag.Bool("check", false, "validate policy and persistent state without sockets or nft changes")
	probe := flag.String("probe", "", "check local DNS over UDP and TCP")
	resolve := flag.String("resolve", "", "resolve an endpoint through the existing loopback resolver")
	runTimeout := flag.Int("run-timeout", 0, "internal bounded native lifecycle command")
	capabilities := flag.Bool("capabilities", false, "native coordinator compatibility")
	flag.Parse()
	if *capabilities {
		return json.NewEncoder(os.Stdout).Encode(map[string]any{"schema": 2, "persistent_dns": true, "bounded_commands": true})
	}
	if *runTimeout != 0 {
		if *runTimeout < 1 || *runTimeout > 30 || flag.NArg() < 1 {
			return errors.New("invalid lifecycle command")
		}
		base, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		ctx, cancel := context.WithTimeout(base, time.Duration(*runTimeout)*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, flag.Arg(0), flag.Args()[1:]...)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		cmd.WaitDelay = 2 * time.Second
		if err := cmd.Run(); err != nil {
			return errors.New("native lifecycle command failed or timed out")
		}
		return nil
	}
	if *probe != "" || *resolve != "" {
		address := *probe
		if address == "" {
			address = "127.0.0.1:53"
		}
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
		defer cancel()
		var ips []string
		for _, network := range []string{"udp", "tcp"} {
			name := "localhost."
			if *resolve != "" {
				name = dns.Fqdn(*resolve)
			}
			for _, kind := range []uint16{dns.TypeA, dns.TypeAAAA} {
				if *resolve == "" && kind != dns.TypeA {
					continue
				}
				m, _, err := (&dns.Client{Net: network, Timeout: 2 * time.Second}).ExchangeContext(ctx, new(dns.Msg).SetQuestion(name, kind), address)
				if err != nil || m.Rcode != dns.RcodeSuccess {
					return errors.New("local DNS probe failed")
				}
				for _, rr := range m.Answer {
					switch v := rr.(type) {
					case *dns.A:
						ips = append(ips, v.A.String())
					case *dns.AAAA:
						ips = append(ips, v.AAAA.String())
					}
				}
			}
			if *resolve != "" {
				break
			}
		}
		if *resolve != "" {
			return json.NewEncoder(os.Stdout).Encode(ips)
		}
		return nil
	}
	if *conf == "" || *state == "" || flag.NArg() != 0 {
		return errors.New("explicit -config and -ledger required")
	}
	f, err := privateOpen(*conf, unix.O_RDONLY)
	if err != nil {
		return errors.New("cannot open DNS policy")
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > 2<<20 {
		return errors.New("invalid DNS policy file")
	}
	d := json.NewDecoder(f)
	d.DisallowUnknownFields()
	var cfg config
	if d.Decode(&cfg) != nil || d.Decode(new(any)) != io.EOF {
		return errors.New("invalid DNS policy JSON")
	}
	p, err := compile(cfg)
	if err != nil {
		return err
	}
	l, err := openLedger(*state, p.ledgerKey(), *initLedger)
	if err != nil {
		return errors.New("cannot open or initialize private DNS ledger")
	}
	defer l.lock.Close()
	if *initLedger {
		return nil
	}
	if *check {
		if p.Persistent {
			return l.loadHistory(p)
		}
		return nil
	}
	r := &resolver{policy: p, writer: &publisher{policy: p, ledger: l, leases: make(map[bindingKey]binding), commit: nftCommit(p)},
		upstream: makeUpstream(p.Upstream), slots: make(chan struct{}, 64), cache: make(map[questionKey]result)}
	if err := r.writer.restore(); err != nil {
		return err
	}
	// A failed bind must not leave a partial UDP/TCP or IPv4/IPv6 service.
	var servers []*dns.Server
	for _, listen := range []string{p.Listen, p.Listen6} {
		if listen == "" {
			continue
		}
		tcp, err := net.Listen("tcp", listen)
		if err != nil {
			return errors.New("cannot bind DNS TCP socket")
		}
		defer tcp.Close()
		udp, err := net.ListenPacket("udp", listen)
		if err != nil {
			return errors.New("cannot bind DNS UDP socket")
		}
		defer udp.Close()
		servers = append(servers,
			&dns.Server{Listener: tcp, Handler: r, ReadTimeout: 3 * time.Second, WriteTimeout: 6 * time.Second, MaxTCPQueries: 32},
			&dns.Server{PacketConn: udp, Handler: r, UDPSize: 1232})
	}
	ends := make(chan error, len(servers))
	for _, s := range servers {
		go func() { ends <- s.ActivateAndServe() }()
	}
	ticker := time.NewTicker(leaseGrace)
	defer ticker.Stop()
	var heartbeat <-chan time.Time
	if p.Virtual {
		t := time.NewTicker(time.Second)
		defer t.Stop()
		heartbeat = t.C
	}
	for {
		select {
		case <-ends:
			return errors.New("DNS listener stopped")
		case now := <-ticker.C:
			r.writer.expire(now)
		case <-heartbeat:
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			base := "inet pkc_virtual_guard s_" + p.Epoch + "_live4"
			err := nftTransaction(ctx, "destroy element "+base+" { 172.31.252.2 }\n"+
				"create element "+base+" { 172.31.252.2 timeout 4s }\n")
			cancel()
			if err != nil {
				return err
			}
		}
	}
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "podkopchik-native-dns:", err)
		os.Exit(1)
	}
}
