#!/usr/bin/env python3
"""Trainer release boundaries, packaging and fail-closed payload loading."""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
COMPONENT = ROOT / "applications/trainer"
CHARTS = {"helm-crds": 4, "helm": 35, "helm-runtimes": 8}


def render(chart, namespace="kubeflow-system"):
    return subprocess.run(
        ["helm", "template", "trainer-test", str(chart), "--namespace", namespace],
        text=True,
        capture_output=True,
        check=False,
    )


def objects(text):
    return [
        resource
        for resource in yaml.load_all(text, Loader=yaml.CSafeLoader)
        if resource
    ]


class TrainerChartTest(unittest.TestCase):
    def test_releases_have_disjoint_ownership_and_retained_definitions(self):
        identities = set()
        for name, count in CHARTS.items():
            result = render(COMPONENT / name)
            self.assertEqual(result.returncode, 0, result.stderr)
            rendered = objects(result.stdout)
            self.assertEqual(len(rendered), count)
            for resource in rendered:
                identity = (
                    resource["apiVersion"],
                    resource["kind"],
                    resource["metadata"]["name"],
                )
                self.assertNotIn(identity, identities)
                identities.add(identity)
                self.assertNotEqual(resource["kind"], "Namespace")
                annotations = resource["metadata"].get("annotations", {})
                self.assertNotIn("helm.sh/hook", annotations)
                if name == "helm-crds":
                    self.assertEqual(resource["kind"], "CustomResourceDefinition")
                    self.assertEqual(annotations.get("helm.sh/resource-policy"), "keep")
                elif name == "helm-runtimes":
                    self.assertEqual(resource["kind"], "ClusterTrainingRuntime")
                    self.assertNotIn("helm.sh/resource-policy", annotations)
                else:
                    self.assertNotIn(
                        resource["kind"],
                        ("CustomResourceDefinition", "ClusterTrainingRuntime"),
                    )
                    if "aggregationRule" in resource:
                        self.assertNotIn("rules", resource)

    def test_all_installable_charts_reject_foreign_release_namespaces(self):
        for name in CHARTS:
            with self.subTest(chart=name):
                result = render(COMPONENT / name, "other")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("kubeflow-system", result.stderr)

    def test_packaged_api_parent_renders_same_objects(self):
        with tempfile.TemporaryDirectory() as temporary:
            subprocess.run(
                [
                    "helm",
                    "package",
                    str(COMPONENT / "helm-crds"),
                    "--destination",
                    temporary,
                ],
                capture_output=True,
                text=True,
                check=True,
            )
            package = next(Path(temporary).glob("*.tgz"))
            direct, packaged = render(COMPONENT / "helm-crds"), render(package)
            self.assertEqual(packaged.returncode, 0, packaged.stderr)
            self.assertEqual(objects(direct.stdout), objects(packaged.stdout))

    def test_missing_definition_fails_parent_render(self):
        with tempfile.TemporaryDirectory() as temporary:
            chart = Path(temporary) / "chart"
            shutil.copytree(COMPONENT / "helm-crds", chart)
            next(
                (chart / "charts/trainer-api-payload/manifests/definitions").glob(
                    "*.yaml"
                )
            ).unlink()
            result = render(chart)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing or empty", result.stderr)

    def test_missing_or_empty_control_plane_and_catalog_payloads_fail(self):
        for name in ("helm", "helm-runtimes"):
            with self.subTest(chart=name), tempfile.TemporaryDirectory() as temporary:
                chart = Path(temporary) / "chart"
                shutil.copytree(COMPONENT / name, chart)
                (chart / "manifests/platform-resources.yaml").write_text("# empty\n")
                result = render(chart)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("missing or empty", result.stderr)


if __name__ == "__main__":
    unittest.main()
