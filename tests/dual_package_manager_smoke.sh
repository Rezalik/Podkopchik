#!/bin/sh
set -eu
sh tests/package_manager_smoke.sh
for manager in opkg apk; do
	sh tests/install_workflow_smoke.sh "$manager"
	sh tests/xray_update_smoke.sh "$manager"
done
echo 'dual package manager matrix OK (isolated mocks; no live router changes)'
