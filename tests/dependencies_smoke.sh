#!/bin/sh

set -eu

grep -q "ip-full" install.sh
grep -q "+ip-full" Makefile
grep -q "nftables-json" install.sh
grep -q "+nftables-json" Makefile
grep -q "rpcd-mod-luci" install.sh
grep -q "+rpcd-mod-luci" Makefile
grep -q "uhttpd" install.sh
grep -q "+uhttpd" Makefile
grep -q 'Installing dependency: $pkg' install.sh
grep -q "ip -V" install.sh
grep -q "iproute2" install.sh
grep -q "iproute2" root/usr/libexec/podkopchik/apply_rules.sh
grep -q "BusyBox ip is not sufficient for fwmark policy routing" root/usr/libexec/podkopchik/apply_rules.sh
grep -q "Missing required dependency: ip-full" root/usr/bin/podkopchikctl

echo "dependency smoke OK"
