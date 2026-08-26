#!/usr/bin/env bash
# Build the test-only LD_PRELOAD observer/fault injector used to prove that
# performance/0001 reaches its alert-only NTSync wait and safely falls back.
set -euo pipefail
cd "$(dirname "$0")"

"${CC:-cc}" -std=gnu11 -O2 -fPIC -shared -Wall -Wextra -Werror \
  -o ntsync-alert-wait-probe.so ntsync-alert-wait-probe.c
echo "built ntsync-alert-wait-probe.so"
