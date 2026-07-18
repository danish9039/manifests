#!/usr/bin/env python3

import subprocess
import tempfile
import unittest
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
LIBRARY_PATH = REPOSITORY_ROOT / "scripts/library.sh"


class HelmSynchronizationLibraryTest(unittest.TestCase):
    def update_application_version(self, application_version, chart_text=None):
        if chart_text is None:
            chart_text = "apiVersion: v2\nappVersion: v1.0.0\n"

        with tempfile.TemporaryDirectory() as temporary_directory:
            chart_path = Path(temporary_directory) / "Chart.yaml"
            chart_path.write_text(chart_text)
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'source "$1"; update_helm_chart_application_version "$2" "$3"',
                    "bash",
                    str(LIBRARY_PATH),
                    str(chart_path),
                    application_version,
                ],
                capture_output=True,
                text=True,
            )
            return result, chart_path.read_text()

    def test_supported_versions_and_commit_shas_are_quoted_exactly(self):
        original_chart = (
            "apiVersion: v2\n"
            "name: test-chart\n"
            "appVersion: v1.0.0\n"
            "annotations:\n"
            "  category: Test\n"
        )
        supported_versions = [
            "v7.15.2",
            "1.2.3-rc.1+build.5",
            "1234567",
            "a" * 40,
        ]

        for application_version in supported_versions:
            with self.subTest(application_version=application_version):
                result, chart_text = self.update_application_version(
                    application_version,
                    chart_text=original_chart,
                )
                expected_chart = original_chart.replace(
                    "appVersion: v1.0.0",
                    f'appVersion: "{application_version}"',
                )

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(chart_text, expected_chart)

    def test_invalid_refs_are_rejected_without_modifying_chart(self):
        original_chart = "apiVersion: v2\nappVersion: v1.0.0\n"
        invalid_refs = [
            "main",
            "123456",
            "a" * 41,
            "12345g7",
            "01.2.3",
            "v1.2.3\nname: injected",
        ]

        for application_version in invalid_refs:
            with self.subTest(application_version=application_version):
                result, chart_text = self.update_application_version(
                    application_version,
                    chart_text=original_chart,
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(chart_text, original_chart)

    def test_duplicate_application_version_fields_fail_atomically(self):
        original_chart = "apiVersion: v2\nappVersion: v1.0.0\nappVersion: v1.0.1\n"

        result, chart_text = self.update_application_version(
            "v7.15.2",
            chart_text=original_chart,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(chart_text, original_chart)


if __name__ == "__main__":
    unittest.main()
