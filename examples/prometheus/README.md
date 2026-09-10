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

## Dashboards

Two Grafana dashboards live in [`grafana/`](grafana/), as provisioning
templates rather than something to paste into the import box.

- **UPS Overview** — one row of KPI tiles per UPS (power source and how long
  it has been in that state, battery charge, runtime, peak load, peak
  temperature). The row repeats over every UPS Prometheus knows about, so
  adding a UPS to `ups.conf` adds a row. Each tile links through to:
- **UPS Detail** — one UPS at a time: per-phase load, input and output voltage,
  battery charge/runtime/voltage/temperature, input, output and bypass
  frequency, a status-flag timeline, and the device identity table.

The `UPS` picker on the overview is multi-select and defaults to *All* — that is
what drives the repeat. On the detail dashboard it selects one UPS, since its
queries match `ups=` exactly.

They need **Grafana 13 or newer**. Both are in the v2 dashboard schema
(`apiVersion: dashboard.grafana.app/v2`), which is what makes the repeating row
possible; older Grafana cannot read the format at all.

### Recording rules first

The per-phase panels query `nut:output_power_percent{phase="L1"}` and friends,
which do not exist until Prometheus computes them.
[`prometheus-rules.yml`](prometheus-rules.yml) is the reason: `nut_exporter`
emits one metric *name* per phase (`network_ups_tools_output_L1_power_percent`
…`L3`), and three names cannot be one query with a per-phase legend. The rules
fold them into one series per quantity with the phase in a label.

```yaml
# in your Prometheus config
rule_files:
  - /etc/prometheus/nut-rules.yml
```

Each rule falls back to the single-phase variable (`ups.load`,
`input.voltage`, `output.voltage`) as `phase="single"`, so the same dashboards
work for a single-phase UPS behind the same `upsd`.

History starts when the rules do — the per-phase panels are empty for time
ranges before you added them.

### Mount into Grafana

```yaml
services:
  grafana:
    volumes:
      - ./grafana/provisioning/dashboards:/etc/grafana/provisioning/dashboards:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards/nut:ro
```

The provider config is [`grafana/provisioning/dashboards/nut.yml`](grafana/provisioning/dashboards/nut.yml);
it drops both dashboards in a **UPS** folder and re-reads the files every 30
seconds. UI edits are discarded on reload — set `allowUiUpdates: true` if you
would rather tune them in Grafana and export the JSON back.

### Data source

The dashboards do not name a data source. Grafana resolves each query against
your **default Prometheus** data source, which is the portable choice for a
template — a UID exported from one Grafana means nothing in another. If your
Prometheus is not the default, pin it by giving each query back its UID:

```bash
uid=my-prometheus-uid
python3 - "$uid" <<'PY'
import json, sys, pathlib
for p in pathlib.Path("grafana/dashboards").glob("*.json"):
    d = json.loads(p.read_text())
    def pin(n):
        if isinstance(n, dict):
            if n.get("kind") == "DataQuery" and n.get("group") == "prometheus":
                n["datasource"] = {"name": sys.argv[1]}
            for v in n.values():
                pin(v)
        elif isinstance(n, list):
            for v in n:
                pin(v)
    pin(d)
    p.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PY
```

In the v2 schema a query's `datasource.name` **is** the data source UID —
`name` is the Kubernetes-style spelling of `uid`, not the display name.
