#!/bin/sh
# Unit tests for lib/render-config.sh. Run inside the built image:
#   docker run --rm -v "$PWD/tests:/tests:ro" nut-snmp:dev sh /tests/render-config.test.sh
set -eu

RENDER="${RENDER:-/usr/local/lib/nut-snmp/render-config.sh}"
failures=0
current=""

start() { current="$1"; }
pass()  { echo "ok   - $current"; }
fail()  { echo "FAIL - $current: $1"; failures=$((failures + 1)); }

# Run the renderer in a throwaway config dir with a clean environment, so a
# leftover variable from one case cannot leak into the next.
render() {
    role="$1"; shift
    workdir="$(mktemp -d)"
    env -i PATH="$PATH" NUT_CONF_DIR="$workdir" "$@" sh "$RENDER" "$role" >"$workdir/.stderr" 2>&1
}
render_expect_fail() {
    role="$1"; shift
    workdir="$(mktemp -d)"
    if env -i PATH="$PATH" NUT_CONF_DIR="$workdir" "$@" sh "$RENDER" "$role" >"$workdir/.stderr" 2>&1; then
        return 1
    fi
    return 0
}

contains() { grep -qF "$2" "$1"; }

# --- single-UPS environment path, SNMPv2c ------------------------------------
start "env path renders a v2c snmp-ups section"
render server SNMP_HOST=192.0.2.10 UPS_NAME=rack NUT_PASSWORD=secret
if ! contains "$workdir/ups.conf" '[rack]'; then fail "missing [rack] section"
elif ! contains "$workdir/ups.conf" 'driver = snmp-ups'; then fail "missing driver"
elif ! contains "$workdir/ups.conf" 'port = 192.0.2.10'; then fail "missing port"
elif ! contains "$workdir/ups.conf" 'snmp_version = v2c'; then fail "v2c is not the default"
elif ! contains "$workdir/ups.conf" 'mibs = auto'; then fail "missing mibs"
elif ! contains "$workdir/ups.conf" 'community = public'; then fail "missing community"
elif grep -qE '^\s*(serial|cable|baud)' "$workdir/ups.conf"; then fail "emitted a serial parameter"
else pass; fi

# --- SNMPv3 ------------------------------------------------------------------
start "v3 credentials are emitted only when set"
render server SNMP_HOST=192.0.2.11 SNMP_VERSION=v3 SNMP_SEC_LEVEL=authPriv \
       SNMP_SEC_NAME=monitor SNMP_AUTH_PASSWORD=authpw SNMP_PRIV_PASSWORD=privpw \
       SNMP_AUTH_PROTOCOL=SHA256 SNMP_PRIV_PROTOCOL=AES NUT_PASSWORD=secret
if ! contains "$workdir/ups.conf" 'snmp_version = v3'; then fail "missing snmp_version"
elif ! contains "$workdir/ups.conf" 'secLevel = authPriv'; then fail "missing secLevel"
elif ! contains "$workdir/ups.conf" 'authProtocol = SHA256'; then fail "missing authProtocol"
elif ! contains "$workdir/ups.conf" 'privPassword = privpw'; then fail "missing privPassword"
else pass; fi

start "unset optional parameters are omitted rather than guessed"
render server SNMP_HOST=192.0.2.12 NUT_PASSWORD=secret
if grep -q 'secLevel' "$workdir/ups.conf"; then fail "emitted an unset v3 parameter"
elif grep -q 'pollfreq' "$workdir/ups.conf"; then fail "emitted pollfreq without POLLFREQ"
else pass; fi

# --- secrets -----------------------------------------------------------------
start "NUT_PASSWORD_FILE is read from disk"
secret="$(mktemp)"; printf 'from-a-file\n' > "$secret"
render server SNMP_HOST=192.0.2.13 NUT_PASSWORD_FILE="$secret"
if ! contains "$workdir/upsd.users" 'password = from-a-file'; then fail "secret file not applied"
else pass; fi

start "SNMP_COMMUNITY_FILE is read from disk"
secret="$(mktemp)"; printf 'sekrit\n' > "$secret"
render server SNMP_HOST=192.0.2.14 SNMP_COMMUNITY_FILE="$secret" NUT_PASSWORD=secret
if ! contains "$workdir/ups.conf" 'community = sekrit'; then fail "community file not applied"
else pass; fi

# --- mounted config passthrough ---------------------------------------------
start "an existing ups.conf is left byte-identical"
workdir="$(mktemp -d)"
cat > "$workdir/ups.conf" <<'UPSCONF'
[apc-rack]
    driver = snmp-ups
    port = 10.0.0.5
    mibs = apcc
UPSCONF
before="$(md5sum < "$workdir/ups.conf")"
env -i PATH="$PATH" NUT_CONF_DIR="$workdir" SNMP_HOST=should-be-ignored \
    NUT_PASSWORD=secret sh "$RENDER" server >/dev/null 2>&1
after="$(md5sum < "$workdir/ups.conf")"
if [ "$before" != "$after" ]; then fail "the renderer rewrote a mounted ups.conf"
elif ! contains "$workdir/upsd.users" 'password = secret'; then fail "upsd.users was not still rendered"
else pass; fi

# --- upsd.conf ---------------------------------------------------------------
start "upsd.conf carries LISTEN and an optional MAXAGE"
render server SNMP_HOST=192.0.2.15 NUT_PASSWORD=secret LISTEN_ADDR=0.0.0.0 LISTEN_PORT=3493 MAXAGE=25
if ! contains "$workdir/upsd.conf" 'LISTEN 0.0.0.0 3493'; then fail "missing LISTEN"
elif ! contains "$workdir/upsd.conf" 'MAXAGE 25'; then fail "missing MAXAGE"
else pass; fi

start "MAXAGE is omitted when unset"
render server SNMP_HOST=192.0.2.16 NUT_PASSWORD=secret
if grep -q MAXAGE "$workdir/upsd.conf"; then fail "emitted MAXAGE without being asked"
else pass; fi

# --- roles -------------------------------------------------------------------
start "the driver role does not require upsd credentials"
render driver SNMP_HOST=192.0.2.17 UPS_NAME=rack
if [ ! -f "$workdir/ups.conf" ]; then fail "ups.conf was not rendered"
elif [ -f "$workdir/upsd.users" ]; then fail "driver rendered upsd.users it has no use for"
else pass; fi

start "upsd.users is not world-readable"
render server SNMP_HOST=192.0.2.18 NUT_PASSWORD=secret
mode="$(stat -c '%a' "$workdir/upsd.users")"
if [ "$mode" != "640" ]; then fail "mode is $mode, expected 640"
else pass; fi

# --- failure modes -----------------------------------------------------------
start "missing SNMP_HOST with no mounted ups.conf fails clearly"
if render_expect_fail server NUT_PASSWORD=secret && contains "$workdir/.stderr" 'SNMP_HOST is unset'; then pass
else fail "did not fail with a usable message"; fi

start "missing NUT_PASSWORD with no mounted upsd.users fails clearly"
if render_expect_fail server SNMP_HOST=192.0.2.19 && contains "$workdir/.stderr" 'NUT_PASSWORD is unset'; then pass
else fail "did not fail with a usable message"; fi

start "an unreadable secret file fails clearly"
if render_expect_fail server SNMP_HOST=192.0.2.20 NUT_PASSWORD_FILE=/nonexistent \
   && contains "$workdir/.stderr" 'not readable'; then pass
else fail "did not fail with a usable message"; fi

echo
if [ "$failures" -eq 0 ]; then
    echo "all tests passed"
else
    echo "$failures test(s) failed"
fi
exit "$failures"
