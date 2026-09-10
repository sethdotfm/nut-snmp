# nut-snmp

A small [Network UPS Tools](https://networkupstools.org/) server for UPSes that
speak **SNMP**, packaged so the driver and `upsd` each run as PID 1 of their own
container.

```
ghcr.io/sethdotfm/nut-snmp
```

Alpine-based, `linux/amd64` and `linux/arm64`.

## Why this exists

Most NUT containers are built around USB-attached UPSes, and it shows when you
point one at a network card:

- `instantlinux/nut-upsd` generates `ups.conf` from environment variables and
  injects a serial parameter, which `snmp-ups` rejects with a fatal error.
- `ghcr.io/tigattack/nut-upsd` states plainly that it "cannot be configured
  through environment variables" and does not document SNMP.

Both also start the driver with `upsdrvctl start` and then `exec upsd`. That
backgrounds the driver, so **the container keeps reporting healthy while serving
stale data** if the driver dies. NUT 2.8 gives drivers and `upsd` a real `-F`
foreground flag, which makes the fix straightforward: run each as its own
process, in its own container, and let the restart policy do its job.

This image does that, adds a healthcheck that proves data is actually fresh, and
leaves your `ups.conf` alone when you mount one.

## Roles

The entrypoint takes a role:

| Command | Runs |
|---|---|
| `server` (default) | `upsd -u nut -F` |
| `driver <ups-name>` | `snmp-ups -a <ups-name> -u nut -F` |
| anything else | `exec`s it, for debugging |

Driver and server containers share a volume mounted at **`/run/nut`**, which
carries the driver state sockets. Both run the same image, so the `nut` uid
matches on either side of the socket.

`upsd` copes with drivers that are not up yet — it reports the UPS as not
connected and picks it up when the socket appears — so no `depends_on` ordering
is needed.

## Configuration

Any file that already exists in `/etc/nut` is left untouched. Mount your own
`ups.conf` and this image will not rewrite a byte of it; everything else is
still generated from the environment.

**Mount a `ups.conf` if you have more than one UPS or mixed vendors.** Per-device
`mibs`, community strings, and SNMP versions belong in a file, not in indexed
environment variables.

### Always from the environment

| Variable | Default | Effect |
|---|---|---|
| `NUT_USER` | `nutmon` | The user in `upsd.users` |
| `NUT_PASSWORD` | *required* | Its password. Your client authenticates with this |
| `LISTEN_ADDR` | `0.0.0.0` | `upsd.conf` `LISTEN` address |
| `LISTEN_PORT` | `3493` | `upsd.conf` `LISTEN` port |
| `MAXAGE` | *NUT default (15)* | Seconds before unrefreshed data is called stale |
| `STATEPATH` | `/run/nut` | Where driver sockets live. Exported to NUT as `NUT_STATEPATH`, which is the variable NUT itself reads |

The generated user gets the `upsmon secondary` role (NUT 2.8 spelling; `slave`
is the deprecated equivalent).

### Single-UPS environment path

Used only when no `ups.conf` is mounted:

| Variable | Default | `ups.conf` key |
|---|---|---|
| `UPS_NAME` | `ups` | section name |
| `SNMP_HOST` | *required* | `port` — accepts `host` or `host:port` |
| `SNMP_VERSION` | `v2c` | `snmp_version` |
| `SNMP_COMMUNITY` | `public` | `community` |
| `MIBS` | `auto` | `mibs` |
| `POLLFREQ` | *NUT default (30)* | `pollfreq` |
| `SNMP_RETRIES` | *NUT default (5)* | `snmp_retries` |
| `SNMP_TIMEOUT` | *NUT default (1)* | `snmp_timeout` |
| `SNMP_SEC_LEVEL` | — | `secLevel` |
| `SNMP_SEC_NAME` | — | `secName` |
| `SNMP_AUTH_PASSWORD` | — | `authPassword` |
| `SNMP_PRIV_PASSWORD` | — | `privPassword` |
| `SNMP_AUTH_PROTOCOL` | — | `authProtocol` |
| `SNMP_PRIV_PROTOCOL` | — | `privProtocol` |
| `DESC` | — | `desc` |
| `EXTRA_UPS_CONF` | — | appended verbatim to the section |

`SNMP_VERSION` defaults to **`v2c`**, deliberately unlike NUT's own `v1`
default. Set `SNMP_VERSION=v1` if your device needs it.

Anything left unset is simply not written, so NUT's defaults stay in force
rather than being replaced by a value this image invented.

### Secrets

`NUT_PASSWORD`, `SNMP_COMMUNITY`, `SNMP_AUTH_PASSWORD`, and `SNMP_PRIV_PASSWORD`
each accept a `_FILE` variant pointing at a mounted secret:

```yaml
environment:
  NUT_PASSWORD_FILE: /run/secrets/nut_password
```

## Health

The healthcheck is role-aware.

On the **server** it lists every UPS `upsd` knows about and reads `ups.status`
from each. `upsc` fails with a stale-data error once a driver stops updating, so
this catches a dead or wedged driver — which process liveness never would. The
failing UPS is named in the output, which matters once more than one sits behind
a single `upsd`:

```console
$ docker inspect -f '{{range .State.Health.Log}}{{.Output}}{{end}}' nut-server
stale or unreachable: apc-rack (Error: Data stale)
```

On a **driver** it checks that the state socket exists, i.e. the driver got past
`upsdrv_initups`. Losing comms mid-flight deliberately does *not* fail it:
`snmp-ups` stays running through an unreachable UPS, which is correct — a restart
would not help — and the resulting staleness is reported by the server.

If you bind `LISTEN_ADDR` to something other than `0.0.0.0`, set
`HEALTHCHECK_HOST` to an address the check can reach.

## Operating notes

- **A driver that restarts in a loop means the UPS is unreachable.** `snmp-ups`
  exits if it cannot reach the device at startup; Docker's restart backoff
  retries. Check the address, community string, and that UDP/161 is open.
- **`mibs = auto` is a starting point, not a destination**, and sometimes not
  even that: it matches on the device's `sysObjectID`, and a device whose OID
  sits *below* a MIB's registered prefix can fail to match at all. Pin the MIB
  once you know it. See [Choosing a MIB](#choosing-a-mib).
- **This cannot shut down your host.** A container has no way to halt the
  machine it runs on. Hosts that need to power down on low battery still need
  their own `upsmon` client pointed at this server's port 3493.
- SNMP community strings and SNMPv3 passwords sit in plaintext in `ups.conf`.
  Keep it `0640` and out of version control. NUT parses the file before it drops
  privileges, so the container's default root user reads a `0640` file that the
  `nut` uid could not — but if you run the container with a non-root `user:`,
  the mounted file has to be readable by *that* uid, since nothing runs as root
  to read it first.

## Choosing a MIB

`mibs = auto` asks `snmp-ups` to read the device's `sysObjectID` and match it
against every MIB it ships. That works often enough to be the default and badly
enough to be worth understanding.

Angle-bracket placeholders are left out of the commands below on purpose: `<`
is shell redirection, so pasting one unedited fails with a syntax error rather
than a useful message. Set these once and the rest copy cleanly.

Find out what your device claims to be:

```bash
NET=nut-snmp_internal      # the driver container's docker network
IP=192.168.1.50
COMMUNITY=public

docker run --rm --network "$NET" alpine sh -c \
  "apk add -q net-snmp-tools && snmpwalk -v2c -c $COMMUNITY $IP 1.3.6.1.2.1.1"
```

`sysObjectID` is the value that drives detection. If `auto` fails — the driver
exits with `No supported device detected` and Docker restarts it in a loop — pin
the MIB by hand and re-run the driver in the foreground to watch it load:

```bash
UPS=sr1-1                  # the section name in ups.conf

docker compose stop "nut-$UPS"
docker run --rm --network "$NET" \
  -v "$PWD/config/ups.conf:/etc/nut/ups.conf:ro" \
  ghcr.io/sethdotfm/nut-snmp:latest \
  sh -c "mkdir -p /run/nut && timeout 45 /usr/lib/nut/snmp-ups -a $UPS -DDD 2>&1 | grep -v 'skip the'"
```

Stop the running driver first — two instances race for the same state socket.
`timeout` matters too: a driver that loads successfully enters its main loop and
never exits on its own.

A successful load prints `Detected MODEL on host IP (mib: NAME VERSION)`. To see
every MIB the binary knows:

```bash
docker run --rm -v "$PWD/config/ups.conf:/etc/nut/ups.conf:ro" \
  ghcr.io/sethdotfm/nut-snmp:latest \
  sh -c "/usr/lib/nut/snmp-ups -a $UPS -x mibs=--list 2>&1"
```

That handling lives in `upsdrv_initups()`, after the config is parsed, so it
needs a real `ups.conf` section to run at all — hence the mount. It prints the
table and exits without touching the network.

**A vendor MIB is not automatically the right one.** NUT's vendor MIBs are
written against whatever hardware the contributor had, so a MIB that matches
your `sysObjectID` may still map a fraction of what the device publishes. Before
settling, check whether the device implements RFC 1628 (the standard UPS MIB) as
well:

```bash
docker run --rm --network "$NET" alpine sh -c \
  "apk add -q net-snmp-tools && snmpwalk -v2c -c $COMMUNITY $IP 1.3.6.1.2.1.33"
```

If that returns a populated tree, compare `mibs = ietf` against the vendor MIB
and keep whichever publishes more. RFC 1628 has real three-phase tables, which
most vendor MIBs in NUT do not.

### Worked example: Schneider Electric Easy UPS 3S (Phoenixtec card)

A 40 kVA `E3SUPS40KF` behind a card reporting `sysObjectID =
.1.3.6.1.4.1.935.1.1.1`, firmware `3.7.DA807.APC.15`. Every step below is a
thing that actually went wrong.

- **SNMPv3 only.** The card's access-control table offered no v1/v2c rows at
  all, so v1 and v2c queries were dropped without a reply — indistinguishable
  from a firewall or a wrong community until you look at the web UI. Ping and
  HTTPS answered fine throughout.
- **`auto` did not match.** Enterprise 935 is Phoenixtec, and NUT's `xppc` MIB
  registers `.1.3.6.1.4.1.935` — but `match_sysoid` walked the whole table
  without matching `.1.3.6.1.4.1.935.1.1.1`. Pinning `mibs = xppc` worked
  immediately via the classic testOID path.
- **`xppc` was still the wrong choice.** It maps nine OIDs, all single-phase, so
  `ups.load` stayed empty on a three-phase unit and there was no
  `battery.runtime` at all.
- **`mibs = ietf` was the answer.** The card implements RFC 1628 in full:
  `battery.runtime`, `battery.voltage`, per-phase `input.L1-N.voltage` /
  `output.L1.power.percent` across all three phases, `ups.firmware`,
  `ups.test.result`.
- **The card reports its serial in `upsIdentManufacturer`**, which NUT maps to
  `ups.mfr`, so the dashboard showed a serial number where the vendor belongs.
  `override.` in `ups.conf` fixes that without patching anything.

```ini
[sr1-1]
    driver = snmp-ups
    port = 172.17.50.121
    snmp_version = v3
    secLevel = authPriv
    secName = nutmon
    authProtocol = SHA
    authPassword = <auth-password>
    privProtocol = AES
    privPassword = <priv-password>
    mibs = ietf
    pollfreq = 30
    snmp_timeout = 3
    snmp_retries = 5
    desc = "Server Room 1 Primary UPS"

    # This card reports its serial in upsIdentManufacturer, which NUT reads as
    # ups.mfr. override. takes any NUT variable.
    override.ups.mfr = "Schneider Electric"
    override.ups.serial = "<serial>"
```

Note that under `ietf` a three-phase UPS publishes `output.L1.power.percent` and
friends rather than a single `ups.load`, because there is no one load figure to
report. Dashboards that expect `ups.load` will show nothing — see
[Three-phase and Prometheus](#three-phase-and-prometheus).

## Quick start, one UPS, no config files

```bash
docker network create nut

docker run -d --name nut-driver --network nut \
  -v nut-run:/run/nut \
  -e UPS_NAME=ups -e SNMP_HOST=192.168.1.50 -e SNMP_COMMUNITY=public \
  ghcr.io/sethdotfm/nut-snmp:latest driver ups

docker run -d --name nut-server --network nut -p 3493:3493 \
  -v nut-run:/run/nut \
  -e UPS_NAME=ups -e SNMP_HOST=192.168.1.50 -e SNMP_COMMUNITY=public \
  -e NUT_PASSWORD=change-me \
  ghcr.io/sethdotfm/nut-snmp:latest server

docker exec nut-server upsc ups@127.0.0.1
```

Both containers get the same environment so each renders the same `ups.conf`;
there is no shared config volume in this mode.

## Alongside an existing PeaNUT

See [`examples/existing-peanut/`](examples/existing-peanut/) for a compose
project that joins PeaNUT's network without touching PeaNUT's own compose file.

Every UPS in `ups.conf` is served by the one `upsd`, so PeaNUT needs a single
new entry appended to `NUT_SERVERS` in its `/config/settings.yml`:

```yaml
NUT_SERVERS:
  # ... existing entries, untouched ...
  - HOST: nut-server
    PORT: 3493
    USERNAME: nutmon
    PASSWORD: change-me   # must match NUT_PASSWORD
```

Adding the server through the PeaNUT UI writes the same file. Note that current
PeaNUT versions no longer read `NUT_HOST`/`NUT_PORT`/`USERNAME`/`PASSWORD`
environment variables — they are silently ignored.

## Three-phase and Prometheus

PeaNUT models a single-phase UPS: three KPI tiles and one voltage chart, keyed
on `ups.load`. A three-phase device under `mibs = ietf` publishes
`output.L1.power.percent` through `L3` and no `ups.load`, so the load tile stays
empty while status, battery charge and runtime work normally.

Rather than reshape that dashboard, send the per-phase data somewhere built for
several series on one axis. [`examples/prometheus/`](examples/prometheus/) adds
[`DRuggeri/nut_exporter`](https://github.com/DRuggeri/nut_exporter) to the
stack: it connects to `upsd` as an ordinary client and turns every NUT variable
into a metric, so `output.L1.power.percent` becomes
`network_ups_tools_output_L1_power_percent{ups="sr1-1"}`.

Both can run at once. They are just two NUT clients.

## Development

```bash
docker build -t nut-snmp:dev .

# Config rendering
docker run --rm -v "$PWD/tests:/tests:ro" nut-snmp:dev sh /tests/render-config.test.sh

# Two containers, a dummy driver, and the driver-death case end to end
./tests/smoke.sh nut-snmp:dev
```

## License

Public domain, via [the Unlicense](LICENSE). Do whatever you want with it; no
attribution required.

NUT itself is GPL-2.0-or-later and is installed from Alpine's package, not
vendored here.
