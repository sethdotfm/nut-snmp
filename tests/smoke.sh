#!/usr/bin/env bash
# End-to-end smoke test against a real container pair, using NUT's dummy-ups in
# place of a UPS. Proves the two-container split works: shared state socket,
# upsd serving, and -- the part that matters -- the server going unhealthy when
# a driver dies, which is the failure the upsdrvctl design used to hide.
#
#   ./tests/smoke.sh [image]
set -euo pipefail

IMAGE="${1:-nut-snmp:dev}"
UPS=smoke
PASSWORD=smoke-password
PREFIX="nut-snmp-smoke-$$"
VOLUME="$PREFIX-run"
DRIVER="$PREFIX-driver"
SERVER="$PREFIX-server"
CONFIG="$(mktemp -d)"

cleanup() {
    docker rm -f "$DRIVER" "$SERVER" >/dev/null 2>&1 || true
    # Removal can race the containers actually going away, which leaks the
    # volume; retry briefly rather than leaving one behind.
    for _ in 1 2 3 4 5; do
        docker volume rm "$VOLUME" >/dev/null 2>&1 && break
        sleep 1
    done
    rm -rf "$CONFIG"
}
trap cleanup EXIT

fail() { echo "FAIL - $*" >&2; exit 1; }

# dummy-loop mode (the .seq extension selects it) keeps republishing, so fresh
# data here means the driver is genuinely alive rather than merely started.
cat > "$CONFIG/dummy.seq" <<'SEQ'
ups.status: OL
battery.charge: 100
input.voltage: 121.0
TIMER 5
ups.status: OL
battery.charge: 99
input.voltage: 120.5
TIMER 5
SEQ

cat > "$CONFIG/ups.conf" <<SEQCONF
[$UPS]
    driver = dummy-ups
    port = dummy.seq
    desc = "smoke test"
SEQCONF

# Docker needs interval*retries (30s * 3) plus NUT's MAXAGE (15s) to call a
# stopped driver stale, so the unhealthy transition needs real patience -- a
# tight deadline here just makes the test flaky.
wait_for_health() {
    local container="$1" want="$2" deadline=$((SECONDS + ${3:-120}))
    while [ "$SECONDS" -lt "$deadline" ]; do
        local state
        state="$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null || echo missing)"
        [ "$state" = "$want" ] && return 0
        sleep 2
    done
    echo "--- last health output ---" >&2
    docker inspect -f '{{range .State.Health.Log}}{{.Output}}{{end}}' "$container" >&2 || true
    docker logs "$container" >&2 || true
    return 1
}

# The Alpine package ships sample configs into /etc/nut. If they ever come back,
# every "did the operator mount this?" check in the entrypoint silently inverts,
# so guard the image itself before testing any behaviour built on top of it.
leftovers="$(docker run --rm --entrypoint sh "$IMAGE" -c 'ls -A /etc/nut 2>/dev/null || true')"
[ -z "$leftovers" ] || fail "the image ships config in /etc/nut: $leftovers"
echo "ok   - /etc/nut ships empty"

docker volume create "$VOLUME" >/dev/null

echo "== starting driver"
# Passthrough role: the driver role is hardwired to snmp-ups by design, so the
# dummy driver is invoked directly.
docker run -d --name "$DRIVER" \
    -v "$VOLUME:/run/nut" \
    -v "$CONFIG/ups.conf:/etc/nut/ups.conf:ro" \
    -v "$CONFIG/dummy.seq:/etc/nut/dummy.seq:ro" \
    "$IMAGE" sh -c 'mkdir -p /run/nut && chown nut:nut /run/nut && exec /usr/lib/nut/dummy-ups -a '"$UPS"' -u nut -F' >/dev/null

echo "== starting server"
docker run -d --name "$SERVER" \
    -v "$VOLUME:/run/nut" \
    -v "$CONFIG/ups.conf:/etc/nut/ups.conf:ro" \
    -e NUT_PASSWORD="$PASSWORD" \
    "$IMAGE" server >/dev/null

wait_for_health "$SERVER" healthy || fail "server never became healthy"
echo "ok   - server reports healthy"

listed="$(docker exec "$SERVER" upsc -l 127.0.0.1)"
[ "$listed" = "$UPS" ] || fail "upsc -l returned '$listed', expected '$UPS'"
echo "ok   - upsc -l lists $UPS"

status="$(docker exec "$SERVER" upsc "$UPS@127.0.0.1" ups.status)"
[ "$status" = "OL" ] || fail "ups.status was '$status', expected OL"
echo "ok   - upsc returns live data"

docker exec "$SERVER" upsc "$UPS@127.0.0.1" battery.charge >/dev/null \
    || fail "battery.charge is not being published"
echo "ok   - battery.charge is published"

# upsd.users must have been rendered from the environment even though ups.conf
# was mounted -- the mixed mounted/generated case the deployment relies on.
docker exec "$SERVER" grep -q "password = $PASSWORD" /etc/nut/upsd.users \
    || fail "upsd.users was not rendered alongside a mounted ups.conf"
echo "ok   - upsd.users rendered next to a mounted ups.conf"

echo "== killing the driver; the server must notice"
docker rm -f "$DRIVER" >/dev/null
wait_for_health "$SERVER" unhealthy 240 || fail "server stayed healthy after the driver died"

output="$(docker inspect -f '{{range .State.Health.Log}}{{.Output}}{{end}}' "$SERVER")"
grep -q "$UPS" <<<"$output" || fail "the health output does not name the failing UPS"
echo "ok   - server went unhealthy and named $UPS"

echo
echo "smoke test passed"
