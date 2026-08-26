#!/usr/bin/env bash
# Build the observer library for an isolated performance/0001 test.
# The observer records the NTSync alert wait and can return EIO for a route test.
set -euo pipefail
cd "$(dirname "$0")"

"${CC:-cc}" -std=gnu11 -O2 -fPIC -shared -Wall -Wextra -Werror \
  -o ntsync-alert-wait-probe.so ntsync-alert-wait-probe.c
echo "built ntsync-alert-wait-probe.so"
