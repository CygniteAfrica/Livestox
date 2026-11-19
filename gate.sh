#!/usr/bin/env bash
# The gate: unit, smoke and regression tests. Exit code is the test runner's own.
set -o pipefail
node ./node_modules/vitest/vitest.mjs run "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E '✓ tests|❯|×|→|Test Files|Tests |FAIL|Error' 
status=${PIPESTATUS[0]}
if [ "$status" -eq 0 ]; then echo "GATE: GREEN"; else echo "GATE: RED (exit $status)"; fi
exit "$status"
