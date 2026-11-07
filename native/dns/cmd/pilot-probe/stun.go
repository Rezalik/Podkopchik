package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"net/netip"
)

// RFC 8489 binding replies provide a bounded nonce-matched UDP control when
// a private echo listener is not reachable. This does not test QUIC or DNS.
func validSTUNReply(reply, request []byte) bool {
	return len(request) == 20 && len(reply) >= 20 && reply[0] == 1 && reply[1] == 1 &&
		int(binary.BigEndian.Uint16(reply[2:4]))+20 == len(reply) && len(reply)%4 == 0 &&
		bytes.Equal(reply[4:20], request[4:20])
}

func probeSTUN(ctx context.Context, endpoint netip.AddrPort, iface string) error {
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
	request := []byte{0, 1, 0, 0, 0x21, 0x12, 0xa4, 0x42, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	var reply [2048]byte
	for i := 0; i < 4; i++ {
		if _, err := rand.Read(request[8:]); err != nil {
			return err
		}
		if _, err := c.Write(request); err != nil {
			return err
		}
		n, err := c.Read(reply[:])
		if err != nil {
			return err
		}
		if !validSTUNReply(reply[:n], request) {
			return errors.New("STUN response did not match the binding challenge")
		}
	}
	fmt.Println("UDP STUN: 4 matched binding replies on one socket")
	return nil
}
