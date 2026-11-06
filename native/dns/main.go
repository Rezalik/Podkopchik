package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"time"

	"github.com/miekg/dns"
	"golang.org/x/sys/unix"
)

func run() error {
	conf := flag.String("config", "", "compiled DNS policy JSON")
	state := flag.String("ledger", "", "private generation watermark file")
	initLedger := flag.Bool("init-ledger", false, "initialize a NEW generation once; do not start listener")
	flag.Parse()
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
	l, err := openLedger(*state, p.key, *initLedger)
	if err != nil {
		return errors.New("cannot open or initialize private DNS ledger")
	}
	defer l.lock.Close()
	if *initLedger {
		return nil
	}
	r := &resolver{policy: p, writer: &publisher{policy: p, ledger: l, leases: make(map[bindingKey]binding), commit: nftCommit(p.Epoch)},
		upstream: makeUpstream(p.Upstream), slots: make(chan struct{}, 64), cache: make(map[questionKey]result)}
	// Open both sockets before serving on either.
	tcp, err := net.Listen("tcp", p.Listen)
	if err != nil {
		return errors.New("cannot bind DNS TCP socket")
	}
	defer tcp.Close()
	udp, err := net.ListenPacket("udp", p.Listen)
	if err != nil {
		return errors.New("cannot bind DNS UDP socket")
	}
	defer udp.Close()
	ends := make(chan error, 2)
	for _, s := range []*dns.Server{
		{Listener: tcp, Handler: r, ReadTimeout: 3 * time.Second, WriteTimeout: 6 * time.Second, MaxTCPQueries: 32},
		{PacketConn: udp, Handler: r, UDPSize: 1232},
	} {
		go func() { ends <- s.ActivateAndServe() }()
	}
	<-ends
	return errors.New("DNS listener stopped")
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "podkopchik-native-dns:", err)
		os.Exit(1)
	}
}
