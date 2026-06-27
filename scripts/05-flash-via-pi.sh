#!/bin/bash
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
exec "$HERE/scripts/05-flash-via-host.sh" "$@"
