package main

import (
	"net"
	"testing"
)

func TestTCPProbeOptionalInterface(t *testing.T) {
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	done := make(chan struct{})
	go func() {
		c, e := l.Accept()
		if e == nil {
			c.Close()
		}
		close(done)
	}()
	if err := run([]string{"tcp", l.Addr().String()}); err != nil {
		t.Fatal(err)
	}
	<-done
	if err := run([]string{"tcp", l.Addr().String(), "pkc-no-iface"}); err == nil {
		t.Fatal("invalid interface accepted")
	}
}
