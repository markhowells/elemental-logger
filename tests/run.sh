#!/usr/bin/env bash
# Unit tests for the deploy tooling. No Docker, no root, no network:
#   tests/run.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; failn=0
ok()   { echo "  ok   $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL $1"; failn=$((failn+1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
RENDER=(python3 -I deploy/lib/render.py --images deploy/images.env --config config)

echo "render"
"${RENDER[@]}" --env tests/fixtures/test.env --out "$T/r1" --version t1 >/dev/null
check "plugin config equals golden (live-shaped) config" \
  "python3 -I -c 'import json,sys; a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); sys.exit(a!=b)' $T/r1/signalk/plugin-config-data/signalk-to-influxdb2.json tests/fixtures/plugin-config.expected.json"
check "allow_readonly absent by default" \
  "python3 -I -c 'import json,sys; sys.exit(\"allow_readonly\" in json.load(open(sys.argv[1]))[\"security\"])' $T/r1/signalk/settings.managed.json"
check "special characters in secrets survive (compose.env, hostapd)" \
  "grep -qF 'INFLUXDB_PASSWORD=influx-pass-\"quoted\"-\\back' $T/r1/compose.env && grep -qF 'wpa_passphrase=wifi-pass-with-&-and-|-chars' $T/r1/hostapd.conf"
check "no unresolved placeholders anywhere" "! grep -r PLACEHOLDER $T/r1"
check "secrets files are not world-readable" "[ \"\$(stat -c %a $T/r1/compose.env)\" = 600 ] && [ \"\$(stat -c %a $T/r1/hostapd.conf)\" = 600 ]"
check "signalk config files are readable by the container user (other-read when not root)" \
  "[ \$(( 0\$(stat -c %a $T/r1/signalk/settings.managed.json) & 4 )) -eq 4 ] && [ \$(( 0\$(stat -c %a $T/r1/signalk/plugin-config-data/signalk-to-influxdb2.json) & 4 )) -eq 4 ]"
check "--check validates without --out (as install.sh and marine-doctor call it)" \
  "${RENDER[*]} --env tests/fixtures/test.env --check"
check "rendering without --out or --check is refused" "! ${RENDER[*]} --env tests/fixtures/test.env"
check "Caddyfile http mode by default" "grep -q '^http://elemental.internal' $T/r1/caddy/Caddyfile && grep -q 'auto_https off' $T/r1/caddy/Caddyfile"
check "dnsmasq wildcard for the domain" "grep -q '^address=/elemental.internal/10.42.0.1' $T/r1/dnsmasq.conf"

cp tests/fixtures/test.env "$T/opts.env"
printf 'TLS_MODE=internal\nINFLUX_RESOLUTION_MS=1000\nINFLUX_IGNORED_PATHS=electrical.switches.bank.*, navigation.x\nSIGNALK_ALLOW_READONLY=true\nDOMAIN=boat.internal\n' >> "$T/opts.env"
"${RENDER[@]}" --env "$T/opts.env" --out "$T/r2" >/dev/null
check "options: typed resolution/list, allow_readonly, internal TLS, custom domain" \
  "python3 -I - $T/r2 <<'PY'
import json,sys
d=sys.argv[1]
c=json.load(open(d+'/signalk/plugin-config-data/signalk-to-influxdb2.json'))['configuration']['influxes'][0]
s=json.load(open(d+'/signalk/settings.managed.json'))
cf=open(d+'/caddy/Caddyfile').read()
assert c['resolution']==1000 and isinstance(c['resolution'],int)
assert c['ignoredPaths']==['electrical.switches.bank.*','navigation.x']
assert s['security']['allow_readonly'] is True
assert 'tls internal' in cf and 'local_certs' in cf and 'signalk.boat.internal' in cf and 'http://' not in cf
PY"

printf 'CAN_INTERFACE=vcan0\n' >> "$T/opts.env"
"${RENDER[@]}" --env "$T/opts.env" --out "$T/r3" >/dev/null
check "CAN_INTERFACE flows into the managed SignalK provider" "grep -q '\"interface\": \"vcan0\"' $T/r3/signalk/settings.managed.json && grep -q '\"interface\": \"can0\"' $T/r1/signalk/settings.managed.json"

for bad in "CAN_INTERFACE=eth0" "WIFI_PASSWORD=changeme123" "INFLUXDB_TOKEN=short" "TLS_MODE=maybe" "DOMAIN=Bad_Domain" "INFLUX_RESOLUTION_MS=-5" "INFLUXDB_PASSWORD=has\$dollar-sign"; do
  k=${bad%%=*}; grep -v "^$k=" tests/fixtures/test.env > "$T/bad.env"; echo "$bad" >> "$T/bad.env"; rm -rf "$T/rbad"
  check "rejects $bad and writes nothing" "! ${RENDER[*]} --env $T/bad.env --out $T/rbad && [ ! -e $T/rbad ]"
done

echo "merge-settings"
node images/signalk/bin/merge-settings.js "$T/r1/signalk/settings.managed.json" "$T/s.json" >/dev/null
check "fresh volume: created from managed template" "[ -f $T/s.json ]"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d["security"]["allow_readonly"]=True; d["vessel"]["name"]="Old"; d["interfaces"]={"x":1}; d["resourcesApi"]={"y":2}; json.dump(d,open(sys.argv[1],"w"))' "$T/s.json"
node images/signalk/bin/merge-settings.js "$T/r1/signalk/settings.managed.json" "$T/s.json" >/dev/null
check "managed keys corrected, stale allow_readonly removed, SignalK-owned keys preserved" \
  "python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(not (d[\"vessel\"][\"name\"]==\"Test Vessel\" and \"allow_readonly\" not in d[\"security\"] and d[\"interfaces\"]=={\"x\":1} and d[\"resourcesApi\"]=={\"y\":2}))' $T/s.json"
check "second merge is a no-op" "node images/signalk/bin/merge-settings.js $T/r1/signalk/settings.managed.json $T/s.json | grep -q 'already in sync'"

echo "marine-update (file:// feed, no docker)"
mk_release() {  # mk_release <version> <apply-exit-code>
  local v=$1 rc=$2 d="$T/rel-$1"; rm -rf "$d"; mkdir -p "$d/deploy"
  printf '#!/usr/bin/env bash\necho applying %s\nexit %s\n' "$v" "$rc" > "$d/deploy/marine-apply"; chmod +x "$d/deploy/marine-apply"
  : > "$d/deploy/images.env"
  tar -czf "$T/marine-$v.tar.gz" -C "$d" .
  printf '{"version":"%s","bundle_url":"file://%s","bundle_sha256":"%s"}\n' "$v" "$T/marine-$v.tar.gz" "$(sha256sum "$T/marine-$v.tar.gz" | cut -d' ' -f1)" > "$T/feed-$v.json"
}
export MARINE_STATE_DIR="$T/state" MARINE_OPT_DIR="$T/opt" MARINE_ENV="$T/none.env"
mkdir -p "$T/opt/releases/0.0.0"; ln -sfn "$T/opt/releases/0.0.0" "$T/opt/current"
mk_release 1.0.0 0; mk_release 2.0.0 1
U=deploy/marine-update
MARINE_UPDATE_URL="file://$T/does-not-exist.json" $U --auto >"$T/o" 2>&1; check "offline: exits 0 quietly" "[ \$? -eq 0 ] && grep -q offline $T/o"
export MARINE_UPDATE_URL="file://$T/feed-1.0.0.json"
$U --check >"$T/o" 2>&1; check "--check reports an update" "grep -q 'update available' $T/o"
$U --auto >"$T/o" 2>&1; check "--auto stages but does not apply (AUTO_APPLY=no)" "grep -q 'AUTO_APPLY=no' $T/o && [ ! -f $T/state/current.json ]"
$U --apply >"$T/o" 2>&1; check "--apply switches current -> 1.0.0" "[ \"\$(basename \$(readlink -f $T/opt/current))\" = 1.0.0 ] && grep -q 1.0.0 $T/state/current.json"
$U --check >"$T/o" 2>&1; check "up to date afterwards" "grep -q 'up to date' $T/o"
# tampered bundle must be refused
export MARINE_UPDATE_URL="file://$T/feed-2.0.0.json"; echo junk >> "$T/marine-2.0.0.tar.gz"
rm -rf "$T/state/staged/2.0.0"; $U --stage >"$T/o" 2>&1; check "checksum mismatch is refused" "grep -q 'checksum mismatch' $T/o && [ ! -f $T/state/staged/READY ]"
mk_release 2.0.0 1; rm -rf "$T/state/staged/2.0.0"
$U >"$T/o" 2>&1; check "failed apply rolls back to the previous release" "[ \"\$(basename \$(readlink -f $T/opt/current))\" = 1.0.0 ] && grep -q 'rolling back' $T/o && [ -f $T/state/failed/2.0.0 ]"
$U --check >"$T/o" 2>&1; check "a release that failed is not retried automatically" "grep -q 'previously failed' $T/o"


echo "doctor"
mkdir -p "$T/stub"
for c in docker curl ip timedatectl systemctl journalctl vcgencmd; do printf '#!/bin/sh\nexit 0\n' > "$T/stub/$c"; chmod +x "$T/stub/$c"; done
cp tests/fixtures/test.env "$T/doc.env"; chmod 600 "$T/doc.env"
PATH="$T/stub:$PATH" MARINE_ENV="$T/doc.env" MARINE_STATE_DIR="$T/docstate" deploy/marine-doctor >"$T/doc.out" 2>&1
check "doctor reports each check exactly once" "[ -z \"\$(grep -E '^(OK|WARN|FAIL) ' $T/doc.out | cut -c7-29 | sort | uniq -d)\" ] && grep -q '^OK    marine.env permissions' $T/doc.out"
check "marine-apply and marine-update agree on the installed-version file" \
  "grep -q 'STATE/current.json' deploy/marine-apply && grep -q 'STATE/current.json\" version' deploy/marine-update"

doctor() {  # doctor <journald Storage> <journal dir> <list-boots output>
    printf '#!/bin/sh\necho "# /usr/lib/x.conf"\necho "Storage=%s"\n' "$1" > "$T/stub/systemd-analyze"
    printf '#!/bin/sh\nprintf "%%b" "%s"\n' "$3" > "$T/stub/journalctl"; chmod +x "$T/stub/systemd-analyze" "$T/stub/journalctl"
    PATH="$T/stub:$PATH" MARINE_ENV="$T/doc.env" MARINE_STATE_DIR="$T/docstate" MARINE_JOURNAL_DIR="$2" MARINE_DEV_DIR="$T/nodev" \
        deploy/marine-doctor >"$T/doc.out" 2>&1
}
HDR='IDX BOOT ID FIRST LAST\n'
mkdir -p "$T/journal/abc" "$T/nojournal"; : > "$T/journal/abc/system.journal"
doctor volatile "$T/journal" "$HDR  0 aaa x y\n"
check "journal: volatile storage fails even with old files present" "grep -q '^FAIL  persistent journal' $T/doc.out"
doctor persistent "$T/nojournal" "$HDR  0 aaa x y\n"
check "journal: no files on disk fails" "grep -q '^FAIL  persistent journal' $T/doc.out"
doctor persistent "$T/journal" "$HDR  0 aaa x y\n"
check "journal: header line is not counted as a boot" "grep -q '^WARN  persistent journal' $T/doc.out"
doctor persistent "$T/journal" "$HDR -1 aaa x y\n  0 bbb x y\n"
check "journal: two boots reported as two" "grep -q '^OK    persistent journal *2 boots' $T/doc.out"
# trixie: the old fake-hwclock name is masked, the load unit is enabled. Offline (no NTP, no RTC).
cat > "$T/stub/systemctl" <<'SH'
#!/bin/sh
for a in "$@"; do [ "$a" = fake-hwclock-load.service ] && exit 0; done
exit 1
SH
doctor persistent "$T/journal" "$HDR  0 aaa x y\n"
check "clock: trixie fake-hwclock is recognised when offline" \
  "grep -q '^WARN  clock' $T/doc.out && grep -q '^WARN  RTC .*fake-hwclock in use' $T/doc.out"
printf '#!/bin/sh\nexit 1\n' > "$T/stub/systemctl"
doctor persistent "$T/journal" "$HDR  0 aaa x y\n"
check "clock: offline with neither RTC nor fake-hwclock still fails" "grep -q '^FAIL  clock' $T/doc.out"
check "the persistent-journal drop-in sorts after Raspberry Pi OS's volatile one" \
  "grep -q '^Storage=persistent' config/journald-marine.conf && grep -q '50-marine-persistent.conf' deploy/marine-apply"

echo "smoke-test safety (stubbed docker; nothing real is touched)"
cat > "$T/stub/docker" <<'SH'
#!/bin/sh
echo "$*" >> "$STUB_LOG"
case "$1 $2" in
    "volume ls") printf '%s\n' $STUB_VOLUMES ;;
    "ps -a") printf '%s\n' $STUB_CONTAINERS ;;
esac
SH
printf '#!/bin/sh\necho "sudo $*" >> "$STUB_LOG"\n' > "$T/stub/sudo"; chmod +x "$T/stub/sudo" "$T/stub/docker"
smoke() {  # smoke <volumes> <containers> <marine.env path>
    : > "$T/stub.log"
    PATH="$T/stub:$PATH" STUB_LOG="$T/stub.log" STUB_VOLUMES="$1" STUB_CONTAINERS="$2" MARINE_ENV="$3" \
        SIGNALK_IMAGE=x tools/smoke-test.sh >"$T/smoke.out" 2>&1
}
untouched() { grep -q REFUSING "$T/smoke.out" && ! grep -q -E 'compose|down|volume rm|^sudo' "$T/stub.log"; }
smoke "pi_influxdb_data" "" "$T/none.env"; rc=$?
check "refuses where pi_* volumes exist, touching nothing" "[ $rc -ne 0 ] && untouched"
smoke "" "influxdb" "$T/none.env"; rc=$?
check "refuses where a stack container exists, touching nothing" "[ $rc -ne 0 ] && untouched"
smoke "" "" "$T/doc.env"; rc=$?
check "refuses on a machine with marine.env, touching nothing" "[ $rc -ne 0 ] && untouched"
check "smoke test overrides every pinned volume and network name" \
  "for n in \$(sed -n 's/^ *name: pi_//p' deploy/docker-compose.yml); do grep -q \"name: smoke_\$n}\" tools/smoke-test.sh || exit 1; done"

echo; echo "$pass passed, $failn failed"; [ "$failn" -eq 0 ]
