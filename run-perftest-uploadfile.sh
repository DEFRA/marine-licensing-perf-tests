#!/bin/bash
set -e
cd "$(dirname "$0")"
rm -rf reports/* logs/* 2>/dev/null || true
mkdir -p reports logs

jmeter -n \
  -t scenarios/exemption-uploadfile.jmx \
  -l "reports/run-$(date +%Y%m%d-%H%M%S).csv" \
  -j logs/perftest.log \
  -e -o reports \
  -Jdomain=marine-licensing-frontend.perf-test.cdp-int.defra.cloud \
  -JstubDomain=cdp-defra-id-stub.perf-test.cdp-int.defra.cloud \
  -JkmlPath="$(pwd)/resources/test-site.kml" \
  -Jjourney=perftest \
  -Jthreads=1 -JrampSeconds=1 -Jloops=1 -JthinkTimeMs=200
