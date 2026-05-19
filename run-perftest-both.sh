#!/bin/bash
# Run both perf-test scenarios (manual-coord + uploadfile) with 1 VU each,
# then merge the CSVs into a single JMeter HTML report.
set -e
cd "$(dirname "$0")"
rm -rf reports/* logs/* 2>/dev/null || true
mkdir -p reports logs

THREADS="${THREADS:-1}"
RAMP_SECONDS="${RAMP_SECONDS:-$THREADS}"
LOOPS="${LOOPS:-1}"
THINK_MS="${THINK_MS:-200}"

COMMON_OPTS=(
  -n
  -Jdomain=marine-licensing-frontend.perf-test.cdp-int.defra.cloud
  -JstubDomain=cdp-defra-id-stub.perf-test.cdp-int.defra.cloud
  -Jjourney=perftest
  -Jthreads="$THREADS" -JrampSeconds="$RAMP_SECONDS" -Jloops="$LOOPS" -JthinkTimeMs="$THINK_MS"
)

echo "=== Load shape: threads=$THREADS ramp=${RAMP_SECONDS}s loops=$LOOPS think=${THINK_MS}ms ==="

echo "=== Running exemption-manual-coordinate ==="
jmeter "${COMMON_OPTS[@]}" \
  -t scenarios/exemption-manual-coordinate.jmx \
  -l reports/manual.csv \
  -j logs/perftest-manual.log

echo "=== Running exemption-uploadfile ==="
jmeter "${COMMON_OPTS[@]}" \
  -t scenarios/exemption-uploadfile.jmx \
  -l reports/uploadfile.csv \
  -j logs/perftest-uploadfile.log \
  -JkmlPath="$(pwd)/resources/test-site.kml"

echo "=== Merging CSVs and generating combined report ==="
head -1 reports/manual.csv > reports/combined.csv
tail -n +2 reports/manual.csv >> reports/combined.csv
tail -n +2 reports/uploadfile.csv >> reports/combined.csv

rm -rf reports/combined-report
jmeter -g reports/combined.csv -o reports/combined-report

echo "=== Done. Combined report: reports/combined-report/index.html ==="
