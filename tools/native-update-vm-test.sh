#!/bin/sh
# No network NIC or router required. All persistent targets are fixture roots.
set -eu
. /mnt/lab/native-vm-only.sh
umask 077
lib=/mnt/lab/native-update
work=$(mktemp -d /tmp/podkopchik-native-update.testXXXXXX)
root=$(mktemp -d /tmp/pkc-component-updateXXXXXX)
trap 'rm -rf "$work" "$root"' EXIT HUP INT TERM
cp "$lib/fixtures/valid.tar.gz" "$work/package.tar.gz"
ucode "$lib/native_update.uc" archive "$work/package.tar.gz"
for file in "$lib/fixtures/"*.tar.gz; do
	[ "$(basename "$file")" != valid.tar.gz ] || continue
	cp "$file" "$work/package.tar.gz"
	if ucode "$lib/native_update.uc" archive "$work/package.tar.gz" >"$work/result" 2>&1; then
		echo "FAIL admitted $(basename "$file")"; exit 1
	fi
	echo "PASS rejected $(basename "$file")"
done
ucode "$lib/native_update.uc" release "$lib/fixtures/releases.json" Rezalik/Podkopchik > "$work/release"
grep -qx latest=native-rc-new "$work/release"
if ucode "$lib/native_update.uc" release "$lib/fixtures/bad-releases.json" Rezalik/Podkopchik >/dev/null 2>&1; then exit 1; fi
echo 'PASS prerelease selection, digest and ordering'
cp "$lib/candidate.tar.gz" "$work/package.tar.gz"
ucode "$lib/native_update.uc" archive "$work/package.tar.gz"
mkdir "$work/package"
tar -xzf "$work/package.tar.gz" -C "$work/package"
mkdir -p "$root/etc/config" "$root/etc/podkopchik/awg" "$root/etc/podkopchik/native-state"
printf '%s\n' preserved-uci > "$root/etc/config/podkopchik"
printf '%s\n' preserved-profile > "$root/etc/podkopchik/awg/fixture.conf"
printf '%s\n' preserved-ledger > "$root/etc/podkopchik/native-state/fixture.json"
export PODKOPCHIK_INSTALL_ROOT="$root"
sh "$work/package/tools/install-native-rc-files.sh" "$work/package"
grep -qx preserved-uci "$root/etc/config/podkopchik"
grep -qx preserved-profile "$root/etc/podkopchik/awg/fixture.conf"
grep -qx preserved-ledger "$root/etc/podkopchik/native-state/fixture.json"
cmp "$work/package/root/usr/libexec/podkopchik/universal_plan.uc" "$root/usr/libexec/podkopchik/universal_plan.uc"
echo 'PASS static install, helper schema and preserved settings/profile/ledger'
# An unsafe late target must fail before overwriting even the first file.
printf '%s\n' old-first-file > "$root/etc/init.d/podkopchik"
rm "$root/www/luci-static/resources/view/podkopchik/updates.js"
ln -s /tmp/not-a-target "$root/www/luci-static/resources/view/podkopchik/updates.js"
if sh "$work/package/tools/install-native-rc-files.sh" "$work/package" >"$work/result" 2>&1; then exit 1; fi
grep -qx old-first-file "$root/etc/init.d/podkopchik"
echo 'PASS full target preflight before writes'
rm "$root/www/luci-static/resources/view/podkopchik/updates.js"
cp "$work/package/root/www/luci-static/resources/view/podkopchik/updates.js" "$root/www/luci-static/resources/view/podkopchik/updates.js"
mkdir "$work/bin"
cat > "$work/bin/cp" <<'SH'
#!/bin/sh
for arg do case "$arg" in */updates.js.native-new.*) exit 1;; esac; done
exec /bin/cp "$@"
SH
chmod 755 "$work/bin/cp"
if PATH="$work/bin:$PATH" sh "$work/package/tools/install-native-rc-files.sh" "$work/package" >"$work/result" 2>&1; then exit 1; fi
grep -qx old-first-file "$root/etc/init.d/podkopchik"
cmp "$root/www/luci-static/resources/view/podkopchik/updates.js" "$work/package/root/www/luci-static/resources/view/podkopchik/updates.js"
grep -qx preserved-uci "$root/etc/config/podkopchik"
echo 'PASS static publication failure compensation'
# Full shell entry point with fake GitHub responses and isolated install root.
# No network, UCI mutation, service control or real target path is involved.
rm "$work/bin/cp"
mkdir "$work/lib"
cp "$lib/native_update.uc" "$work/lib/"
cp "$lib/native_update.sh" "$work/lib/"
cat > "$work/lib/native_runtime.sh" <<'SH'
#!/bin/sh
echo '{"pending":null,"recovery_policy":"transactional"}'
SH
cat > "$work/bin/cat" <<'SH'
#!/bin/sh
if [ "$*" = /tmp/sysinfo/board_name ]; then echo xiaomi,redmi-router-ax6000-stock; else exec /bin/cat "$@"; fi
SH
cat > "$work/bin/uci" <<'SH'
#!/bin/sh
echo Rezalik/Podkopchik
SH
cat > "$work/bin/curl" <<'SH'
#!/bin/sh
out=
for arg do if [ "$out" = next ]; then out="$arg"; break; fi; [ "$arg" != -o ] || out=next; done
case "$*" in *api.github.com*) exec /bin/cp "$NATIVE_TEST_WORK/releases.json" "$out";;
 *) exec /bin/cp "$NATIVE_TEST_WORK/package.tar.gz" "$out";; esac
SH
chmod 755 "$work/bin/"*
ucode -e 'import {readfile} from "fs";let r=json(readfile(ARGV[0]));
	for(let v in r)if(v.tag_name=="native-rc-new"){v.assets[0].digest="sha256:"+ARGV[1];v.assets[0].size=+ARGV[2];}printf("%J\n",r);' \
	"$lib/fixtures/releases.json" "$(sha256sum "$work/package.tar.gz" | awk '{print $1}')" "$(wc -c < "$work/package.tar.gz")" > "$work/releases.json"
printf '%s\n' '{"phase":"active","pending":null,"repair":false}' > "$root/etc/podkopchik/native-state/runtime.json"
export PODKOPCHIK_LIB="$work/lib" PODKOPCHIK_CONFIG_DIR="$root/etc/podkopchik" NATIVE_TEST_WORK="$work"
PATH="$work/bin:$PATH" sh "$lib/native_update.sh" install
grep -qx preserved-uci "$root/etc/config/podkopchik"
grep -qx preserved-profile "$root/etc/podkopchik/awg/fixture.conf"
grep -qx preserved-ledger "$root/etc/podkopchik/native-state/fixture.json"
echo 'PASS full Native update entry point with runtime lock and isolated fake GitHub'
printf '%s\n' do-not-overwrite > "$root/etc/init.d/podkopchik"
ucode -e 'import {readfile} from "fs";let r=json(readfile(ARGV[0]));
	for(let v in r)if(v.tag_name=="native-rc-new")v.assets[0].digest="sha256:"+join("",map([1,2,3,4],()=>"0000000000000000"));printf("%J\n",r);' \
	"$work/releases.json" > "$work/bad.json"
mv "$work/releases.json" "$work/good.json"
mv "$work/bad.json" "$work/releases.json"
if PATH="$work/bin:$PATH" sh "$lib/native_update.sh" install >"$work/result" 2>&1; then exit 1; fi
grep -q 'archive SHA256 mismatch' "$work/result"
grep -qx do-not-overwrite "$root/etc/init.d/podkopchik"
mv "$work/good.json" "$work/releases.json"
printf '%s\n' '{"phase":"active","pending":"pending-fixture","repair":false}' > "$root/etc/podkopchik/native-state/runtime.json"
if PATH="$work/bin:$PATH" sh "$lib/native_update.sh" install >"$work/result" 2>&1; then exit 1; fi
grep -q 'not confirmed and active' "$work/result"
grep -qx do-not-overwrite "$root/etc/init.d/podkopchik"
echo 'PASS bad archive digest and pending Apply refused before writes'
echo 'Native package VM acceptance PASS (not a physical router/network acceptance)'
