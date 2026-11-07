package main

import (
	"errors"
	"net"
)

func bindDNSDevice(_ *net.Dialer, _ dnsTransport) error {
	return errors.New("protected tunnel DNS requires the Linux kernel adapter")
}
