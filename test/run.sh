#!/usr/bin/env bash
#
# test/run.sh — runs test/inner.sh against this checkout in a throwaway Debian
# container (bash 5 and mawk, as on the Ubuntu servers). Needs docker. Removes
# the container when done. Exit 0 when every check passed.
#   TEST_IMAGE=mirror.gcr.io/library/python:3.12-slim test/run.sh   (if Docker Hub rate-limits)
#
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="${TEST_IMAGE:-python:3.12-slim}"
docker rm -f -v sem-test >/dev/null 2>&1
docker run -d --name sem-test -v "$here:/src:ro" -v "$here/test:/t:ro" "$image" sleep 1h >/dev/null || exit 1
docker exec sem-test bash -c 'apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq curl cron util-linux >/dev/null 2>&1'
docker exec sem-test bash /t/inner.sh
rc=$?
docker rm -f -v sem-test >/dev/null 2>&1
exit $rc
