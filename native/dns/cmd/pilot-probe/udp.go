package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"time"
)

const echoMagic = "pkc-udp1"
const echoSize = len(echoMagic) + 24

func serveEcho(endpoint netip.AddrPort, lifetime time.Duration) error {
	c, err := net.ListenUDP("udp4", net.UDPAddrFromAddrPort(endpoint))
	if err != nil {
		return err
	}
	defer c.Close()
	fmt.Println("UDP echo ready")
	if err := c.SetDeadline(time.Now().Add(lifetime)); err != nil {
		return err
	}
	var b [echoSize + 1]byte
	for {
		n, src, err := c.ReadFromUDPAddrPort(b[:])
		if e, ok := err.(net.Error); ok && e.Timeout() {
			return nil
		}
		if err != nil {
			return err
		}
		// Equal-sized replies only, to the address that sent the challenge.
		if n == echoSize && string(b[:len(echoMagic)]) == echoMagic {
			_, _ = c.WriteToUDPAddrPort(b[:n], src)
		}
	}
}

func probeEcho(ctx context.Context, endpoint netip.AddrPort, iface string) error {
	d := net.Dialer{}
	if iface != "" {
		if err := bindDevice(&d, iface); err != nil {
			return err
		}
	}
	c, err := d.DialContext(ctx, "udp4", endpoint.String())
	if err != nil {
		return err
	}
	defer c.Close()
	if deadline, ok := ctx.Deadline(); ok {
		if err := c.SetDeadline(deadline); err != nil {
			return err
		}
	}
	var request [echoSize]byte
	var reply [echoSize + 1]byte
	copy(request[:], echoMagic)
	for i := 0; i < 4; i++ {
		if _, err := rand.Read(request[len(echoMagic):]); err != nil {
			return err
		}
		if _, err := c.Write(request[:]); err != nil {
			return err
		}
		n, err := c.Read(reply[:])
		if err != nil {
			return err
		}
		if n != len(request) || !bytes.Equal(reply[:n], request[:]) {
			return errors.New("UDP response did not match the challenge")
		}
	}
	fmt.Println("UDP echo: 4 matched replies on one socket")
	return nil
}
