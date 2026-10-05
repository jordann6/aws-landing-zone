#!/usr/bin/env python3
"""Compatibility entry point for the renamed landing-zone input exporter."""

from pathlib import Path
import runpy

if __name__ == "__main__":
    runpy.run_path(str(Path(__file__).with_name("prepare-workload-inputs.py")), run_name="__main__")
