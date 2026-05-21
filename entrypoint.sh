#!/bin/sh
set -x

echo "run_id: $RUN_ID in $ENVIRONMENT"

# CDP "Profile" textbox is passed in as the PROFILE env var. Interpret it as a
# space-separated list of KEY=VALUE pairs and export each. This lets the CDP UI
# override TEST_SCENARIO, THREADS, LOOPS, etc. without rebuilding the image.
# Examples:
#   PROFILE="THREADS=10 LOOPS=5"
#   PROFILE="TEST_SCENARIO=exemption-uploadfile"
#   PROFILE="THREADS=20 LOOPS=10 RAMP_SECONDS=60 THINK_TIME_MS=1000"
if [ -n "${PROFILE}" ]; then
  for kv in ${PROFILE}; do
    case "${kv}" in
      *=*) export "${kv}" ;;
    esac
  done
fi

NOW=$(date +"%Y%m%d-%H%M%S")

if [ -z "${JM_HOME}" ]; then
  JM_HOME=/opt/perftest
fi

JM_SCENARIOS=${JM_HOME}/scenarios
JM_REPORTS=${JM_HOME}/reports
JM_LOGS=${JM_HOME}/logs

mkdir -p ${JM_REPORTS} ${JM_LOGS}

# TEST_SCENARIO accepts one or more scenarios separated by spaces or commas.
# When more than one is supplied each is run sequentially and their sample
# CSVs are concatenated into a single JMeter HTML report.
# Supported names: exemption-manual-coordinate | exemption-uploadfile
TEST_SCENARIO=${TEST_SCENARIO:-"exemption-manual-coordinate exemption-uploadfile"}
# Normalise commas -> spaces
TEST_SCENARIOS=$(echo "${TEST_SCENARIO}" | tr ',' ' ')

# Frontend under test
SERVICE_ENDPOINT=${SERVICE_ENDPOINT:-marine-licensing-frontend.${ENVIRONMENT}.cdp-int.defra.cloud}
SERVICE_PORT=${SERVICE_PORT:-443}
SERVICE_URL_SCHEME=${SERVICE_URL_SCHEME:-https}

# cdp-defra-id-stub (auth provider in dev / perf-test once stub is deployed there)
STUB_ENDPOINT=${STUB_ENDPOINT:-cdp-defra-id-stub.${ENVIRONMENT}.cdp-int.defra.cloud}
STUB_PORT=${STUB_PORT:-443}
STUB_URL_SCHEME=${STUB_URL_SCHEME:-https}

# CDP egress proxy (used inside CDP). Empty for local / direct internet runs.
PROXY_HOST=${PROXY_HOST:-}
PROXY_PORT=${PROXY_PORT:-}

# Load shape - tune per run
THREADS=${THREADS:-3}
RAMP_SECONDS=${RAMP_SECONDS:-30}
LOOPS=${LOOPS:-5}
THINK_TIME_MS=${THINK_TIME_MS:-500}

# Path to the KML fixture inside the container (used by file-upload scenarios)
KML_PATH=${KML_PATH:-${JM_HOME}/resources/test-site.kml}

# Journey/UI variant: dev (legacy: project-name -> how-do-you-want-to-provide directly) or
# perftest (newer UI: project-name -> task-list hub, review-site-details + cya intermediates).
# Both use /confirm-individual (JMX auto-registers Citizen users with empty relationships).
# Auto-defaults to perftest for ENVIRONMENT=perf-test, dev otherwise. Override via JOURNEY_VARIANT.
if [ -z "${JOURNEY_VARIANT}" ]; then
  if [ "${ENVIRONMENT}" = "perf-test" ]; then
    JOURNEY_VARIANT=perftest
  else
    JOURNEY_VARIANT=dev
  fi
fi

run_exit_code=0
SAMPLE_CSVS=""

for scenario in ${TEST_SCENARIOS}; do
  SCENARIOFILE=${JM_SCENARIOS}/${scenario}.jmx
  REPORTFILE=${JM_REPORTS}/${NOW}-perftest-${scenario}-report.csv
  LOGFILE=${JM_LOGS}/perftest-${scenario}.log

  if [ ! -f "${SCENARIOFILE}" ]; then
    echo "ERROR: scenario file not found: ${SCENARIOFILE}"
    run_exit_code=1
    continue
  fi

  echo "=== Running scenario: ${scenario} ==="
  jmeter -n -t "${SCENARIOFILE}" -l "${REPORTFILE}" -j "${LOGFILE}" -f \
    -Jenv="${ENVIRONMENT}" \
    -Jdomain="${SERVICE_ENDPOINT}" \
    -Jport="${SERVICE_PORT}" \
    -Jprotocol="${SERVICE_URL_SCHEME}" \
    -JstubDomain="${STUB_ENDPOINT}" \
    -JstubPort="${STUB_PORT}" \
    -JstubProtocol="${STUB_URL_SCHEME}" \
    -JproxyHost="${PROXY_HOST}" \
    -JproxyPort="${PROXY_PORT}" \
    -Jthreads="${THREADS}" \
    -JrampSeconds="${RAMP_SECONDS}" \
    -Jloops="${LOOPS}" \
    -JthinkTimeMs="${THINK_TIME_MS}" \
    -JkmlPath="${KML_PATH}" \
    -Jjourney="${JOURNEY_VARIANT}"
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "scenario ${scenario} exited with ${rc}"
    run_exit_code=$rc
  fi
  SAMPLE_CSVS="${SAMPLE_CSVS} ${REPORTFILE}"
done

# Merge sample CSVs and generate a single combined HTML report.
COMBINED_CSV=${JM_REPORTS}/${NOW}-perftest-combined.csv
first=1
for csv in ${SAMPLE_CSVS}; do
  if [ ! -f "${csv}" ]; then continue; fi
  if [ $first -eq 1 ]; then
    head -1 "${csv}" > "${COMBINED_CSV}"
    first=0
  fi
  tail -n +2 "${csv}" >> "${COMBINED_CSV}"
done

if [ -s "${COMBINED_CSV}" ]; then
  echo "=== Generating combined JMeter HTML report ==="
  rm -rf "${JM_REPORTS}/html"
  jmeter -g "${COMBINED_CSV}" -o "${JM_REPORTS}/html" -f
  # Copy the dashboard files up to ${JM_REPORTS} so the existing S3 upload picks them up.
  if [ -d "${JM_REPORTS}/html" ]; then
    cp -R "${JM_REPORTS}/html/." "${JM_REPORTS}/"
    rm -rf "${JM_REPORTS}/html"
  fi
fi

if [ -n "$RESULTS_OUTPUT_S3_PATH" ]; then
  if [ -f "$JM_REPORTS/index.html" ]; then
      for csv in ${SAMPLE_CSVS} "${COMBINED_CSV}"; do
        [ -f "${csv}" ] && aws --endpoint-url=$S3_ENDPOINT s3 cp "${csv}" "$RESULTS_OUTPUT_S3_PATH/$(basename ${csv})"
      done
      aws --endpoint-url=$S3_ENDPOINT s3 cp "$JM_REPORTS" "$RESULTS_OUTPUT_S3_PATH" --recursive
      if [ $? -eq 0 ]; then
        echo "CSV report file and test results published to $RESULTS_OUTPUT_S3_PATH"
      fi
   else
      echo "$JM_REPORTS/index.html is not found"
      exit 1
   fi
else
   echo "RESULTS_OUTPUT_S3_PATH is not set"
fi

exit $run_exit_code
