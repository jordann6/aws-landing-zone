"""The responder's known alarms must include the standing roots, and a root that is not
applied must contribute nothing instead of failing the export."""

import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location(
    "export_incident_inputs", Path(__file__).resolve().parents[1] / "scripts/export-incident-inputs.py"
)
export = importlib.util.module_from_spec(spec)
spec.loader.exec_module(export)


class KnownAlarmsTests(unittest.TestCase):
    def test_merges_central_uptime_and_backup_alarms(self):
        roots = {
            "uptime": {"alarm_names": ["uptime-monitor-site-down", "uptime-monitor-high-latency"]},
            "backup-verify": {"alarm_name": "backup-verify-stale-backup"},
        }
        with mock.patch.object(export, "outputs", side_effect=lambda root: roots[root]):
            names = export.known_alarms({"alarm_names": ["rds-cpu-high"]})
        self.assertEqual(
            names,
            [
                "backup-verify-stale-backup",
                "rds-cpu-high",
                "uptime-monitor-high-latency",
                "uptime-monitor-site-down",
            ],
        )

    def test_unapplied_roots_are_skipped(self):
        def missing(root):
            raise subprocess.CalledProcessError(1, "terraform")

        with mock.patch.object(export, "outputs", side_effect=missing):
            self.assertEqual(export.known_alarms({"alarm_names": ["rds-cpu-high"]}), ["rds-cpu-high"])


if __name__ == "__main__":
    unittest.main()
