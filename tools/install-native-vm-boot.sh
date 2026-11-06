#!/bin/sh
# Install a persistent boot fixture into a disposable QEMU ext4 disk only.
set -eu
. /mnt/lab/native-vm-only.sh
grep -q ' / ext4 ' /proc/mounts || { echo 'Persistent VM disk required' >&2; exit 1; }
mkdir -p -m 700 /etc/pkc-native-vm-state
[ ! -e /etc/init.d/pkc-native-vm-boot ]
cp /mnt/lab/native-vm-boot.init /etc/init.d/pkc-native-vm-boot
chmod 755 /etc/init.d/pkc-native-vm-boot
/etc/init.d/pkc-native-vm-boot enable
/etc/init.d/pkc-native-vm-boot start
