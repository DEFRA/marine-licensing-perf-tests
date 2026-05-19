# marine-licensing-perf-tests

JMeter performance tests for the Marine Licensing service. Drives the full exemption submission flow through the **marine-licensing-frontend**, exercising the backend API behind it. Packaged as a Docker image and run by CDP's perf-test framework.

## Scenarios

- **`exemption-manual-coordinate`** — submits an exemption with a circular site entered as WGS84 lat/lon + width.
- **`exemption-uploadfile`** — same journey but the site polygon comes from an uploaded KML file.

## Environment variables

| Var | Default | Purpose |
|---|---|---|
| `ENVIRONMENT` | `local` | Substituted into frontend + stub hostnames; drives `JOURNEY_VARIANT` default |
| `TEST_SCENARIO` | `"exemption-manual-coordinate exemption-uploadfile"` | Space- or comma-separated list. Each runs sequentially and their CSVs are merged into one report |
| `SERVICE_ENDPOINT` | `marine-licensing-frontend.${ENVIRONMENT}.cdp-int.defra.cloud` | Override the frontend hostname |
| `STUB_ENDPOINT` | `cdp-defra-id-stub.${ENVIRONMENT}.cdp-int.defra.cloud` | Override the stub hostname |
| `SERVICE_PORT` / `SERVICE_URL_SCHEME` | `443` / `https` | |
| `STUB_PORT` / `STUB_URL_SCHEME` | `443` / `https` | |
| `THREADS` | `3` | Concurrent VUs |
| `RAMP_SECONDS` | `30` | Ramp-up |
| `LOOPS` | `5` | Iterations per VU (per scenario) |
| `THINK_TIME_MS` | `500` | Pause between steps |
| `KML_PATH` | `/opt/perftest/resources/test-site.kml` | KML fixture path |
| `JOURNEY_VARIANT` | auto from `ENVIRONMENT` | `dev` or `perftest` |
| `PROXY_HOST` / `PROXY_PORT` | empty | CDP egress proxy (auto-set by CDP) |
| `RESULTS_OUTPUT_S3_PATH` | empty | S3 destination for the report (auto-set by CDP) |

## Run on CDP

`entrypoint.sh` is the container's entrypoint. CDP supplies `ENVIRONMENT`, `PROXY_*`, and `RESULTS_OUTPUT_S3_PATH` automatically — you typically don't need to set anything else. Each run executes both scenarios and uploads one combined JMeter HTML report to S3.

### Overriding parameters from the CDP UI

The CDP "Profile" textbox is parsed as a space-separated list of `KEY=VALUE` pairs and each value is exported as an env var before JMeter runs. Use it to change load shape or pick scenarios without rebuilding the image:

| Profile textbox content | Effect |
|---|---|
| *(Profile=No / blank)* | both scenarios, defaults: 3 VU × 5 loops × 30s ramp × 500ms think |
| `THREADS=1 LOOPS=1 RAMP_SECONDS=1` | smoke run |
| `THREADS=10 LOOPS=10 RAMP_SECONDS=60` | medium load |
| `TEST_SCENARIO=exemption-uploadfile` | only the upload-file scenario, default load |
| `TEST_SCENARIO=exemption-manual-coordinate THREADS=20 LOOPS=10 RAMP_SECONDS=60 THINK_TIME_MS=1000` | stress the manual flow |

CDP's "Choose existing" dropdown remembers each value you've entered before, so frequently-used combos become named presets automatically. See the [Environment variables](#environment-variables) table for the full list of keys that can appear in `PROFILE`.

## Run via Docker locally

```bash
docker build . -t mlp-perf

docker run --rm \
  -v "$(pwd)/reports:/opt/perftest/reports" \
  -e ENVIRONMENT=perf-test \
  -e THREADS=1 -e RAMP_SECONDS=1 -e LOOPS=1 -e THINK_TIME_MS=200 \
  mlp-perf

open reports/index.html
```

## Run without Docker (local JMeter)

Convenience wrappers:

```bash
./run-dev-smoke.sh             # manual scenario, dev
./run-dev-uploadfile.sh        # uploadfile scenario, dev
./run-perftest-smoke.sh        # manual scenario, perf-test
./run-perftest-uploadfile.sh   # uploadfile scenario, perf-test
./run-perftest-both.sh         # both scenarios, perf-test, merged report
```

`run-perftest-both.sh` honours `THREADS`, `RAMP_SECONDS`, `LOOPS`, `THINK_MS` env overrides:

```bash
THREADS=5 RAMP_SECONDS=30 LOOPS=5 ./run-perftest-both.sh
```

Or call JMeter directly:

```bash
jmeter -n \
  -t scenarios/exemption-manual-coordinate.jmx \
  -l reports/run.csv -j logs/run.log -e -o reports \
  -Jdomain=marine-licensing-frontend.perf-test.cdp-int.defra.cloud \
  -JstubDomain=cdp-defra-id-stub.perf-test.cdp-int.defra.cloud \
  -Jjourney=perftest \
  -Jthreads=1 -JrampSeconds=1 -Jloops=1 -JthinkTimeMs=200
```

For the file-upload variant, point `kmlPath` at the local fixture:

```bash
jmeter -n \
  -t scenarios/exemption-uploadfile.jmx \
  -l reports/file-run.csv -j logs/file.log -e -o reports \
  -JkmlPath="$(pwd)/resources/test-site.kml" \
  -Jjourney=perftest \
  -Jthreads=1 -Jloops=1
```

## Reading the report

After a run JMeter writes:

- `reports/index.html` — interactive dashboard
- `reports/statistics.json` — machine-readable per-transaction stats
- `reports/*.csv` — raw sample logs (one per scenario, plus a merged `*-combined.csv` when both scenarios run)

What to look at, in order:

1. **Requests Summary** (pie chart on the landing page) — pass vs fail. Anything less than 100% pass, jump to the Errors panel.
2. **Statistics table** — one row per transaction. The columns that matter:
   - `90% Line` / `95% Line` (p90/p95) — best honest "users see this or better" numbers; tune SLAs against p95
   - `Median` (p50) — typical user experience
   - `Error %` — should be 0
   - `Average` and `Max` are easy to read but misleading under load (outliers skew them) — prefer the percentiles
3. **Charts → Over Time → Response Times Over Time** — should be a flat horizontal line per transaction. Upward drift = backend degrading under sustained load (pool exhaustion, GC, DB queue). Spikes = individual slow requests.
4. **Charts → Over Time → Active Threads Over Time** — sanity check that VUs ramped to `THREADS` as expected.
5. **Charts → Throughput → Hits Per Second** — overall req/s. Plateau = system's steady-state ceiling.

**APDEX** on the landing page is a single 0.00–1.00 score (defaults: satisfied <500 ms, tolerating <1500 ms). Our exemption pages legitimately take 2–7s due to backend writes + GOV.UK template rendering, so absolute APDEX will look low — track it **relative to the baseline below**, not against the 1.0 ideal.

Baseline on `perf-test` with 1 VU × 1 iteration per scenario (0 errors):

| Transaction | manual ms | uploadfile ms |
|---|---:|---:|
| TX-LOGIN (once per VU) | 10,880 | 8,104 |
| TX-01 Project Name | 2,446 | 1,858 |
| TX-01b Site details intro (perftest hub) | 2,282 | 1,661 |
| TX-02 coordinates type | 2,351 | 1,946 |
| TX-03 multiple-sites / file-type | 2,332 | 1,779 |
| TX-04 activity dates / GET upload page | 2,412 | 1,732 |
| TX-05 activity description / Upload KML | 2,372 | 2,011 |
| TX-06 coordsEntry=single / Wait for upload | 2,330 | 9,623 |
| TX-07 coordSystem=WGS84 / activity dates | 2,341 | 1,812 |
| TX-08 centre coords / activity description | 2,347 | 1,902 |
| TX-08b review-site-details (perftest hub) | — | 2,091 |
| TX-09 width-of-site / Public Register | 2,489 | 3,599 |
| TX-09b review-site-details (perftest hub) | 2,425 | — |
| TX-10 Public Register / Check answers + submit | 4,735 | 5,667 |
| TX-11 Check answers + submit | 7,114 | — |

`TX-LOGIN` runs once per VU; iterations 2+ skip it, so per-exemption cost drops sharply as `LOOPS` increases.

## Layout

```
.
├── Dockerfile                          # FROM defradigital/cdp-perf-test-docker
├── entrypoint.sh                       # Runs each TEST_SCENARIO, merges reports, uploads to S3
├── scenarios/
│   ├── exemption-manual-coordinate.jmx # Manual circular site (WGS84)
│   └── exemption-uploadfile.jmx        # KML file upload (curl-based upload step)
├── resources/
│   └── test-site.kml                   # KML fixture
├── run-dev-smoke.sh                    # Local: manual scenario, dev
├── run-dev-uploadfile.sh               # Local: uploadfile scenario, dev
├── run-perftest-smoke.sh               # Local: manual scenario, perf-test
├── run-perftest-uploadfile.sh          # Local: uploadfile scenario, perf-test
├── run-perftest-both.sh                # Local: both scenarios, perf-test, merged report
├── compose.yml                         # Local-stack (localstack + redis + container) for E2E
├── reports/                            # Generated; gitignored
└── logs/                               # Generated; gitignored
```
