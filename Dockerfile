FROM defradigital/cdp-perf-test-docker:latest

WORKDIR /opt/perftest

COPY scenarios/ ./scenarios/
COPY resources/ ./resources/
COPY entrypoint.sh .
COPY user.properties .

ENV S3_ENDPOINT=https://s3.eu-west-2.amazonaws.com
ENV TEST_SCENARIO="exemption-manual-coordinate exemption-uploadfile"

ENTRYPOINT [ "./entrypoint.sh" ]
