#!/usr/bin/env python3
"""Create a sample Predator alert extract for demo/UAT."""

from pathlib import Path

from src.imports.service import create_sample_predator_file

if __name__ == "__main__":
    path = Path("sample_data/predator_alerts_sample.xlsx")
    create_sample_predator_file(path)
    print(f"Wrote {path}")