//go:build !linux

package main

import (
	"errors"
	"net"
)

func bindDevice(_ *net.Dialer, _ string) error {
	return errors.New("binding the UDP preflight to a device requires Linux")
}
