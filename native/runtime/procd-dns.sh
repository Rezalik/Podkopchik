#!/bin/sh
# Shared registration; the caller owns activation of policy and kernel guards.
native_dns_instance() {
	procd_open_instance main
	procd_set_param command "$@"
	procd_set_param respawn 3600 1 3
	procd_set_param term_timeout 5
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}
