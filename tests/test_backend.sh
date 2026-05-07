#!/usr/bin/env bash
set -euo pipefail

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1 && timeout --version >/dev/null 2>&1; then
    timeout 300s "$@"
  else
    "$@"
  fi
}

zig build test -Dembed-ui=false -Dbuild-ui=false --summary all
run_with_timeout zig build test-integration -Dembed-ui=false -Dbuild-ui=false --summary all
