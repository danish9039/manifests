#!/usr/bin/env python3
"""The first KServe release revision must fit into its release Secret.

tests/helm_release_size.py measures every scenario a chart declares, and the
KServe descriptor declares the complete installation only. The installer
creates the release with payload.resources.enabled=false, though, so the record
that Kubernetes has to accept first is the definitions-only one; it is the
record that exceeded 1,048,576 bytes on 2026-09-13. This test measures that
revision with the functions of the storage guard, from the chart directory and
from the packaged chart.

It compiles the Go encoder of the storage guard and therefore needs Go, unlike
tests/kserve_helm_chart_test.py.
"""

import importlib.util
import json
import tempfile
import unittest

from pathlib import Path

MODULE_PATH = Path(__file__).with_name("helm_release_size.py")
_MODULE_SPEC = importlib.util.spec_from_file_location("helm_release_size", MODULE_PATH)
sizing = importlib.util.module_from_spec(_MODULE_SPEC)
_MODULE_SPEC.loader.exec_module(sizing)

COMPONENT = "kserve"
DEFINITIONS_ONLY = "payload.resources.enabled=false"
CUSTOM_RESOURCE_DEFINITION_COUNT = 16


def rendered_kinds(release_record):
    manifest = json.loads(release_record).get("manifest") or ""
    return [
        line.removeprefix("kind: ")
        for line in manifest.splitlines()
        if line.startswith("kind: ")
    ]


class KServeDefinitionsOnlyReleaseSizeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sizing.require_helm_major_version(sizing.REQUIRED_HELM_MAJOR_VERSION)
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        root = Path(cls.temporary.name)
        cls.encoder = sizing.build_encoder(root)
        cls.environment = sizing.helm_environment(root / "helm")
        chart, cls.descriptor = sizing.discover_units()[COMPONENT]
        cls.scenario = cls.descriptor["scenarios"]["platform"]
        cls.chart = sizing.prepare_chart(
            chart, cls.descriptor, root / "charts", cls.environment
        )
        cls.packages = root / "packages"

    def assert_first_revision_fits(self, chart, scenario):
        record = sizing.dry_run_release(
            chart, self.descriptor, scenario, self.environment, DEFINITIONS_ONLY
        )
        self.assertEqual(
            rendered_kinds(record),
            ["CustomResourceDefinition"] * CUSTOM_RESOURCE_DEFINITION_COUNT,
        )
        encoded_bytes = sizing.encoded_release_bytes(self.encoder, record)
        print(f"{chart.name}: definitions-only release record {encoded_bytes:,} bytes")
        self.assertEqual(sizing.verdict(encoded_bytes), "ok", encoded_bytes)

    def test_the_definitions_only_revision_fits_from_the_chart_directory(self):
        self.assert_first_revision_fits(self.chart, self.scenario)

    def test_the_definitions_only_revision_fits_from_the_packaged_chart(self):
        sizing.run(
            ["helm", "package", str(self.chart), "--destination", str(self.packages)],
            env=self.environment,
        )
        (archive,) = self.packages.glob("kserve-*.tgz")
        # The values file is read from the chart directory; an archive has none.
        values = {"values": str(self.chart / self.scenario["values"])}

        self.assert_first_revision_fits(archive, values)


if __name__ == "__main__":
    unittest.main()
