#!/bin/sh
# nut-snmp entrypoint.
#
#   driver <ups-name>   run snmp-ups for one UPS in the foreground (PID 1)
#   server              run upsd in the foreground (PID 1)
#   <anything else>     exec it, for debugging
#
# Each NUT process is PID 1 of its own container. That is the whole point: a
# driver that dies takes its container with it and the restart policy brings it
# back, instead of leaving a healthy-looking container serving stale data.
set -eu

STATEPATH="${STATEPATH:-/run/nut}"
ROLE_MARKER=/run/nut-snmp.role

# NUT resolves its state path from NUT_STATEPATH and only falls back to the
# compiled-in default (/var/run/nut on Alpine, which is a symlink to /run/nut).
# Exporting it here is what makes STATEPATH actually move the sockets; without
# it we would create and chown a directory the drivers then ignore.
export NUT_STATEPATH="$STATEPATH"

log() { echo "nut-snmp: $*" >&2; }
die() { log "error: $*"; exit 1; }

prepare_statepath() {
    mkdir -p "$STATEPATH"
    # Shared between the driver and server containers via a named volume, which
    # Docker creates root-owned. Both containers run this same image, so the nut
    # uid matches on either side of the socket.
    if [ "$(id -u)" = "0" ]; then
        chown nut:nut "$STATEPATH"
        chmod 0750 "$STATEPATH"
    fi
}

case "${1:-server}" in
    driver)
        shift
        if [ $# -gt 0 ]; then
            ups="$1"; shift
        else
            ups="${UPS_NAME:-}"
        fi
        [ -n "$ups" ] || die "the driver role needs a UPS name: 'driver <name>', or set UPS_NAME"

        /usr/local/lib/nut-snmp/render-config.sh driver
        prepare_statepath
        printf 'driver %s\n' "$ups" > "$ROLE_MARKER"

        # -F keeps the driver in the foreground; without it snmp-ups forks away
        # and the container survives its death.
        log "starting snmp-ups for '$ups'"
        exec /usr/lib/nut/snmp-ups -a "$ups" -u nut -F "$@"
        ;;

    server)
        shift || true
        /usr/local/lib/nut-snmp/render-config.sh server
        prepare_statepath
        printf 'server\n' > "$ROLE_MARKER"

        log "starting upsd on ${LISTEN_ADDR:-0.0.0.0}:${LISTEN_PORT:-3493}"
        exec upsd -u nut -F "$@"
        ;;

    *)
        exec "$@"
        ;;
esac
