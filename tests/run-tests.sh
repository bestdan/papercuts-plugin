#!/usr/bin/env bash
# Test runner for the papercuts plugin.
#
# Discovers every *.test.sh in the repo and runs it. Passing with zero tests is
# a deliberate, supported state: this runner exists from the first commit so
# every later task has a green baseline to add to, rather than inheriting a
# runner and a failure at the same time.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC2207
suites=($(find "$root" -name '*.test.sh' -type f -not -path '*/.git/*' | sort))

if [ "${#suites[@]}" -eq 0 ]; then
  echo "0 suites found — nothing to run (this is a pass)"
  exit 0
fi

failed=0
for suite in "${suites[@]}"; do
  echo "--- ${suite#"$root"/}"
  if bash "$suite"; then
    echo "    ok"
  else
    echo "    FAILED"
    failed=$((failed + 1))
  fi
done

echo
if [ "$failed" -eq 0 ]; then
  echo "${#suites[@]} suite(s) passed"
  exit 0
fi

echo "$failed of ${#suites[@]} suite(s) failed"
exit 1
