#!/usr/bin/env bash
# Compatibility entry point; see docs/quickstart.md for artifact setup.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/gate.py" cold "$@"
