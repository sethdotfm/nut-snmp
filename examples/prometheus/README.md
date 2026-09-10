# nut-snmp + Prometheus

For three-phase UPSes, and for anywhere you want history rather than a live
snapshot.

Under `mibs = ietf` a three-phase device publishes `output.L1.power.percent`
through `L3` and **no `ups.load`** — there is no single load figure to report.
Dashboards keyed on `ups.load` (PeaNUT among them) show an empty tile. Three
series on one axis is a graphing problem, so this example hands the data to
Prometheus instead of reshaping a dashboard.

[`nut_exporter`](https://github.com/DRuggeri/nut_exporter) connects to `upsd` as
an ordinary NUT client and exposes every variable as a metric:

```
network_ups_tools_output_L1_power_percent{ups="sr1-1"} 21
network_ups_tools_output_L2_power_percent{ups="sr1-1"} 22
network_ups_tools_output_L3_power_percent{ups="sr1-1"} 23
network_ups_tools_battery_runtime{ups="sr1-1"} 3420
```

It needs no SNMP access of its own, only a route to `upsd`, and it is just
another client — run it alongside PeaNUT rather than instead of it.

## Setup

```bash
cp .env.example .env                        # set NUT_PASSWORD
cp config/ups.conf.example config/ups.conf  # fill in your UPS
```

Set `NUT_EXPORTER_PASSWORD` in `docker-compose.yml` to match `NUT_PASSWORD`, and
point `networks.metrics.name` at Prometheus's own network:

```bash
docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' prometheus
```

Add the job from [`prometheus-scrape.yml`](prometheus-scrape.yml) to your
Prometheus config, then:

```bash
docker compose up -d
docker exec nut-server upsc sr1-1@127.0.0.1
```

## Two things that will catch you

- **The metrics path is `/ups_metrics`.** `nut_exporter` keeps `/metrics` for
  its own Go runtime telemetry, so scraping the default path gets you a healthy
  target and no UPS data.
- **`--nut.vars_enable=` must be empty.** Its default is a single-phase list
  (`ups.load`, `input.voltage`, `battery.charge`, …) which silently drops every
  per-phase variable — exactly the ones you came here for.
