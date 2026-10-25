#!/bin/sh

# Shared by procd, CLI, probes and the core updater. Never execute selector text.
CORE_DIR="${PODKOPCHIK_CORE_DIR:-/usr/libexec/podkopchik-core}"

xray_source() {
	if [ -f "$CORE_DIR/selected" ]; then
		cat "$CORE_DIR/selected"
	else
		echo package
	fi
}

xray_bin() {
	case "$(xray_source)" in
		package) command -v xray 2>/dev/null || command -v xray-core 2>/dev/null ;;
		official|rollback) [ -x "$CORE_DIR/xray" ] && printf '%s\n' "$CORE_DIR/xray" ;;
		*) return 1 ;;
	esac
}
