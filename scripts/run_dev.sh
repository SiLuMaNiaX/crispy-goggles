#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONPATH=.
python scripts/generate_sample_extract.py
exec uvicorn src.api.main:app --host 0.0.0.0 --port 8000 --reload