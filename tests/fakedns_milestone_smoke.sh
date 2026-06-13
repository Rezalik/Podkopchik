#!/bin/sh

set -eu

grep -q "option fakedns_enabled '0'" root/etc/config/podkopchik
grep -q "option fakedns_hijack_dns '0'" root/etc/config/podkopchik

grep -q "FakeDNS MVP was verified" README.md
grep -q "FakeDNS MVP validation milestone" docs/SPEC.md
grep -q "FakeDNS MVP acceptance" docs/ACCEPTANCE.md
grep -q "X/Twitter app" README.md
grep -q "X/Twitter app" docs/ACCEPTANCE.md

grep -q "198.18.0.0/15" tests/generate_fakedns_smoke.sh
grep -q "FakeDNS pool is not direct-routed" README.md
grep -q "FakeDNS pool is not in reserved4" README.md

! grep -R "udp dport 443" root/usr/libexec/podkopchik root/usr/bin root/etc/init.d
! grep -E "meta l4proto .*udp.*tproxy|udp.*tproxy" root/usr/libexec/podkopchik/apply_rules.sh

echo "FakeDNS milestone smoke OK"
