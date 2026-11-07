package main

import (
	"errors"
	"net"
	"syscall"

	"golang.org/x/sys/unix"
)

func bindDNSDevice(d *net.Dialer, t dnsTransport) error {
	i, err := net.InterfaceByName(t.Interface)
	if err != nil || i.Index != t.Index {
		return errors.New("DNS tunnel identity unavailable")
	}
	d.Control = func(_, _ string, raw syscall.RawConn) error {
		var bindErr error
		err := raw.Control(func(fd uintptr) {
			if bindErr = unix.BindToDevice(int(fd), t.Interface); bindErr == nil {
				bindErr = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_MARK, t.Mark)
			}
		})
		if err != nil {
			return err
		}
		return bindErr
	}
	return nil
}
