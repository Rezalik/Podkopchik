package main

import (
	"net"
	"syscall"

	"golang.org/x/sys/unix"
)

func bindDevice(d *net.Dialer, iface string) error {
	i, err := net.InterfaceByName(iface)
	if err != nil {
		return err
	}
	d.Control = func(_, _ string, raw syscall.RawConn) error {
		var bindErr error
		if err := raw.Control(func(fd uintptr) {
			bindErr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IP, unix.IP_BOUND_IF, i.Index)
		}); err != nil {
			return err
		}
		return bindErr
	}
	return nil
}
