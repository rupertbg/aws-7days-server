#!/bin/bash
# Entry point: re-extract the bootstrap from instance.yml, lint it, run both
# suites. Needs bash, python3, jq and (optionally) shellcheck.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
rc=0

for tool in python3 jq; do
  command -v "$tool" >/dev/null || { echo "tests: $tool is required"; exit 1; }
done

rm -rf build
python3 lib/extract.py || exit 1

echo
echo "== template references =="
python3 lib/check-refs.py || rc=1

echo
echo "== shell syntax =="
for f in build/run.sh build/server-set.sh build/bin/*; do
  bash -n "$f" || { echo "  FAIL $f does not parse"; rc=1; }
done
[ "$rc" -eq 0 ] && echo "  ok   every extracted script parses"

if command -v shellcheck >/dev/null; then
  echo
  echo "== shellcheck =="
  # SC1090: the supervision scripts source a path built from the server slug,
  # which is the point. SC2050: a resolved CloudFormation parameter is a
  # literal here but a real value at deploy time.
  shellcheck -s bash -S warning -e SC1090,SC2050 build/run.sh build/bin/* \
    && echo "  ok   no findings"
  [ "${PIPESTATUS[0]:-0}" -eq 0 ] || rc=1
else
  echo
  echo "== shellcheck == (not installed, skipped)"
fi

for suite in server-set supervision; do
  echo
  echo "== $suite =="
  bash "$suite.test.sh" || rc=1
done

echo
[ "$rc" -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit $rc
