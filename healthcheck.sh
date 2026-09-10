#!/bin/sh
# Role-aware container health.
#
#   server: upsd answers, and every UPS it knows about has non-stale data. This
#           is the check that catches a dead or wedged driver -- upsc fails with
#           "data stale" once the driver stops updating, which a process-liveness
#           check would never notice.
#   driver: the driver's state socket exists, i.e. it got past upsdrv_initups.
#           Comms lost mid-flight deliberately does NOT fail here: snmp-ups stays
#           running through an unreachable UPS (correct -- restarting would not
#           help), and the staleness that results is reported by the server.
set -eu

MARKER=/run/nut-snmp.role
STATEPATH="${STATEPATH:-/run/nut}"
HEALTHCHECK_HOST="${HEALTHCHECK_HOST:-127.0.0.1}"
PORT="${LISTEN_PORT:-3493}"

[ -r "$MARKER" ] || { echo "not started yet: no $MARKER"; exit 1; }
read -r role name < "$MARKER"

case "$role" in
    driver)
        sock="$STATEPATH/snmp-ups-$name"
        [ -S "$sock" ] || { echo "driver socket missing: $sock"; exit 1; }
        echo "driver ok: $name"
        ;;

    server)
        # upsc writes "Init SSL without certificate database" to stderr on every
        # invocation. Merging it into stdout would feed that banner to the loop
        # below as if it were a list of UPS names, so the streams stay separate
        # and stderr is kept only for the diagnostic.
        err="$(mktemp)"
        trap 'rm -f "$err"' EXIT

        if ! list="$(upsc -l "$HEALTHCHECK_HOST:$PORT" 2>"$err")"; then
            echo "upsd not answering on $HEALTHCHECK_HOST:$PORT: $(tr '\n' ' ' < "$err")"
            exit 1
        fi
        [ -n "$list" ] || { echo "upsd has no UPS definitions"; exit 1; }

        rc=0
        checked=""
        # Split on newlines only: a UPS name is a whole line, and a stray
        # sentence on stdout should be skipped rather than split into words.
        IFS='
'
        for ups in $list; do
            case "$ups" in
                ''|*[!A-Za-z0-9._-]*) continue ;;   # not a UPS name
            esac
            if ! upsc "$ups@$HEALTHCHECK_HOST:$PORT" ups.status >/dev/null 2>"$err"; then
                # Name the UPS: with several devices behind one upsd, "unhealthy"
                # is useless unless it says which one. docker inspect surfaces
                # this in .State.Health.Log[].Output.
                echo "stale or unreachable: $ups ($(tr '\n' ' ' < "$err"))"
                rc=1
            fi
            checked="$checked $ups"
        done
        unset IFS

        [ -n "$checked" ] || { echo "upsd listed no usable UPS names"; exit 1; }
        [ "$rc" = 0 ] && echo "server ok:$checked"
        exit "$rc"
        ;;

    *)
        echo "unknown role in $MARKER: $role"
        exit 1
        ;;
esac
