#!/usr/bin/env bash
# One-time install.  Needs internet ONCE (Python packages + spaCy model);
# after this the tool runs fully offline.
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v uv >/dev/null 2>&1; then
  echo "uv not found. Install it from https://docs.astral.sh/uv/ then re-run." >&2
  exit 1
fi
uv sync
echo
echo "Installed.  Try:"
echo "  uv run transcript-deid run examples --roster examples/roster.csv --out examples/deid --print"
echo "  uv run transcript-deid review --out examples/deid --roster examples/roster.csv"
