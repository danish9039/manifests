#!/usr/bin/env python3
"""Guard every installable chart against the Helm release Secret limit.

See tests/helm_release_size.py for the mechanism and its limitation. The
fixture tests document the three facts the guard exists for: a large chart
fails outright, a template switch that renders less does not shrink the
embedded chart, and a thin parent chart that carries the same chart as a
dependency stores only the rendered manifest.
"""

import base64
import importlib.util
import json
import random
import shlex
import shutil
import subprocess
import tempfile
import unittest

from pathlib import Path

import yaml

MODULE_PATH = Path(__file__).with_name("helm_release_size.py")
_MODULE_SPEC = importlib.util.spec_from_file_location("helm_release_size", MODULE_PATH)
sizing = importlib.util.module_from_spec(_MODULE_SPEC)
_MODULE_SPEC.loader.exec_module(sizing)

FIXTURE_DESCRIPTOR = {
    "component": "fixture",
    "releaseName": "fixture",
    "namespace": "default",
}
PARENT_DESCRIPTOR = {
    "component": "parent",
    "releaseName": "fixture",
    "namespace": "default",
}


def write_fixture_chart(directory, random_bytes):
    """Write a chart whose one template reads a large payload with .Files.Get.

    The payload is a ConfigMap carrying base64 text of `random_bytes` random
    bytes, so it compresses about as poorly as real custom resource
    definitions do and its size is reproducible.
    """
    chart = Path(directory) / "fixture"
    (chart / "templates").mkdir(parents=True)
    (chart / "manifests").mkdir()
    (chart / "Chart.yaml").write_text("apiVersion: v2\nname: fixture\nversion: 0.1.0\n")
    (chart / "values.yaml").write_text("render: true\n")
    (chart / "templates" / "payload.yaml").write_text(
        '{{- if .Values.render }}\n{{ .Files.Get "manifests/payload.yaml" }}\n{{- end }}\n'
    )
    text = base64.b64encode(random.Random(0).randbytes(random_bytes)).decode()
    lines = "\n".join(
        "    " + text[start : start + 76] for start in range(0, len(text), 76)
    )
    (chart / "manifests" / "payload.yaml").write_text(
        "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: fixture-payload\n"
        "  namespace: default\ndata:\n  blob: |\n" + lines + "\n"
    )
    return chart


def write_thin_parent(directory, child):
    """Wrap `child` as the only dependency of an otherwise empty chart."""
    parent = Path(directory) / "parent"
    (parent / "charts").mkdir(parents=True)
    shutil.copytree(child, parent / "charts" / child.name)
    (parent / "Chart.yaml").write_text("apiVersion: v2\nname: parent\nversion: 0.1.0\n")
    return parent


def rendered_objects(release_record):
    # Helm omits the manifest field from a record that rendered nothing.
    manifest = json.loads(release_record).get("manifest") or ""
    return sorted(
        (document for document in yaml.safe_load_all(manifest) if document),
        key=lambda document: (document["kind"], document["metadata"]["name"]),
    )


class HelmReleaseSizeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.helm = sizing.require_helm_major_version(sizing.REQUIRED_HELM_MAJOR_VERSION)
        cls.temporary = tempfile.TemporaryDirectory()
        root = Path(cls.temporary.name)
        cls.encoder = sizing.build_encoder(root)
        cls.environment = sizing.helm_environment(root / "helm")
        cls.work = root / "work"
        cls.work.mkdir()

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def measure_fixture(self, chart, descriptor, *set_arguments):
        record = sizing.dry_run_release(
            chart, descriptor, {}, self.environment, *set_arguments
        )
        return sizing.encoded_release_bytes(self.encoder, record), record

    def test_discovery_covers_every_installable_chart_and_scenario(self):
        descriptors = sizing.discover_units()

        self.assertGreaterEqual(len(descriptors), 1)
        for component, (chart, descriptor) in descriptors.items():
            self.assertTrue((chart / "Chart.yaml").is_file(), component)
            self.assertGreaterEqual(len(descriptor["scenarios"]), 1, component)
            for name, scenario in descriptor["scenarios"].items():
                if scenario.get("values"):
                    self.assertTrue(
                        (chart / scenario["values"]).is_file(), f"{component}/{name}"
                    )

    def test_every_installable_chart_fits_the_release_secret(self):
        descriptors = sizing.discover_units()
        expected = sum(
            len(descriptor["scenarios"]) for _, descriptor in descriptors.values()
        )

        measurements = sizing.measure(
            descriptors, self.encoder, self.work / "charts", self.environment
        )

        print(f"\nhelm {self.helm}\n{sizing.format_table(measurements)}")
        self.assertEqual(len(measurements), expected)
        failures = [
            sizing.explain(measurement)
            for measurement in measurements
            if measurement.encoded_bytes > sizing.MAX_SECRET_BYTES
        ]
        self.assertEqual(failures, [], "\n".join(failures))

    def test_the_advertised_reproduction_command_measures_one_component(self):
        """A failure must name a command that works from the repository root."""
        command = sizing.reproduction_command("kubeflow-platform")

        result = subprocess.run(
            shlex.split(command),
            cwd=sizing.REPOSITORY_ROOT,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("kubeflow-platform", result.stdout)
        self.assertIn("1 charts measured", result.stdout)
        self.assertNotIn("FAIL", result.stdout + result.stderr)

    def test_encoder_rejects_a_rendered_manifest(self):
        chart = write_fixture_chart(self.work / "reject", 1_000)
        rendered = sizing.run(
            ["helm", "template", "fixture", str(chart)], env=self.environment
        )

        with self.assertRaises(RuntimeError) as context:
            sizing.encoded_release_bytes(self.encoder, rendered)

        self.assertIn("not helm template", str(context.exception))

    def test_a_large_chart_exceeds_the_limit(self):
        chart = write_fixture_chart(self.work / "large", 1_000_000)

        stored, _ = self.measure_fixture(chart, FIXTURE_DESCRIPTOR)

        self.assertGreater(stored, sizing.MAX_SECRET_BYTES)

    def test_a_template_switch_does_not_shrink_the_embedded_chart(self):
        chart = write_fixture_chart(self.work / "switch", 1_000_000)

        rendering, _ = self.measure_fixture(chart, FIXTURE_DESCRIPTOR)
        not_rendering, record = self.measure_fixture(
            chart, FIXTURE_DESCRIPTOR, "render=false"
        )

        self.assertEqual(rendered_objects(record), [])
        self.assertGreater(not_rendering, sizing.MAX_SECRET_BYTES)
        self.assertGreater(not_rendering, rendering / 3)

    def test_a_thin_parent_stores_only_the_rendered_manifest(self):
        chart = write_fixture_chart(self.work / "parent-case", 600_000)
        parent = write_thin_parent(self.work / "parent-case", chart)

        direct, direct_record = self.measure_fixture(chart, FIXTURE_DESCRIPTOR)
        wrapped, wrapped_record = self.measure_fixture(
            parent, PARENT_DESCRIPTOR, "fixture.render=true"
        )

        self.assertGreater(direct, sizing.MAX_SECRET_BYTES)
        self.assertLessEqual(wrapped, sizing.MAX_SECRET_BYTES)
        self.assertEqual(
            rendered_objects(wrapped_record), rendered_objects(direct_record)
        )


if __name__ == "__main__":
    unittest.main()
