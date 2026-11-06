package main

import (
	"net"
	"syscall"

	"golang.org/x/sys/unix"
)

func bindDevice(d *net.Dialer, iface string) error {
	if _, err := net.InterfaceByName(iface); err != nil {
		return err
	}
	d.Control = func(_, _ string, raw syscall.RawConn) error {
		var bindErr error
		if err := raw.Control(func(fd uintptr) { bindErr = unix.BindToDevice(int(fd), iface) }); err != nil {
			return err
		}
		return bindErr
	}
	return nil
}
