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
| `STATEPATH` | `/run/nut` | Where driver sockets live |

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
- **`mibs = auto` is a starting point, not a destination.** It matches on the
  device's `sysObjectID`. Once the UPS connects, check `upsc <name>@127.0.0.1
  ups.mfr` and pin the MIB it resolved to, so a firmware update cannot shift the
  detection under you. `/usr/lib/nut/snmp-ups -a <name> -DD` inside the
  container shows the negotiation; `mibs=--list` prints the candidates.
- **This cannot shut down your host.** A container has no way to halt the
  machine it runs on. Hosts that need to power down on low battery still need
  their own `upsmon` client pointed at this server's port 3493.
- SNMP community strings sit in plaintext in `ups.conf`. Keep it `0640` and out
  of version control.

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

## Development

```bash
docker build -t nut-snmp:dev .

# Config rendering
docker run --rm -v "$PWD/tests:/tests:ro" nut-snmp:dev sh /tests/render-config.test.sh

# Two containers, a dummy driver, and the driver-death case end to end
./tests/smoke.sh nut-snmp:dev
```

## License

MIT. See [LICENSE](LICENSE).
