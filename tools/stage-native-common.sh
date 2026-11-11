#!/bin/sh
# Workstation-only architecture-independent payload staging.
set -eu
[ ! -f /etc/openwrt_release ]
[ "$#" = 1 ]
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case "$1" in /*) ;; *) exit 2;; esac
[ ! -e "$1/root" ] && [ ! -e "$1/i18n" ]
mkdir -p "$1/root" "$1/i18n/ru"
cp -R "$base/root/." "$1/root/"
cp "$base/i18n/ru/podkopchik.ru.lmo" "$1/i18n/ru/"
[ ! -e "$1/root/usr/libexec/podkopchik/podkopchik-native-dns" ]
