#!/usr/bin/env python3
"""KubeRay wrapper defaults, definition ownership and installer boundaries."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "experimental/ray/kuberay-operator/helm"
DEFINITION_NAMES = {
    "rayclusters.ray.io",
    "rayjobs.ray.io",
    "rayservices.ray.io",
    "raycronjobs.ray.io",
}


def documents(text):
    return [item for item in yaml.load_all(text, Loader=yaml.CSafeLoader) if item]


class RayChartTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.chart = Path(cls.directory.name) / "chart"
        shutil.copytree(CHART, cls.chart)
        environment = {
            **os.environ,
            "HELM_CONFIG_HOME": str(Path(cls.directory.name) / "config"),
            "HELM_CACHE_HOME": str(Path(cls.directory.name) / "cache"),
            "HELM_DATA_HOME": str(Path(cls.directory.name) / "data"),
        }
        subprocess.run(
            [
                "helm",
                "repo",
                "add",
                "kuberay",
                "https://ray-project.github.io/kuberay-helm/",
            ],
            check=True,
            env=environment,
        )
        subprocess.run(
            ["helm", "dependency", "build", str(cls.chart)],
            check=True,
            env=environment,
        )
        cls.rendered = cls.render("--include-crds")

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    @classmethod
    def render(cls, *arguments):
        return documents(
            subprocess.check_output(
                [
                    "helm",
                    "template",
                    "kuberay-operator",
                    str(cls.chart),
                    "--namespace",
                    "kubeflow",
                    *arguments,
                ],
                text=True,
            )
        )

    def test_source_pin_dependency_and_lock_agree(self):
        version = re.search(
            r"^KUBERAY_RELEASE_VERSION \?= (.+)$",
            (ROOT / "experimental/ray/Makefile").read_text(),
            re.MULTILINE,
        ).group(1)
        chart = yaml.safe_load((CHART / "Chart.yaml").read_text())
        lock = yaml.safe_load((CHART / "Chart.lock").read_text())
        repository = re.search(
            r"^KUBERAY_HELM_CHART_REPO \?= (.+)$",
            (ROOT / "experimental/ray/Makefile").read_text(),
            re.MULTILINE,
        ).group(1)
        self.assertEqual(chart["dependencies"][0]["repository"], repository)
        self.assertEqual(chart["appVersion"], version)
        self.assertEqual(chart["dependencies"], lock["dependencies"])
        self.assertEqual(chart["dependencies"][0]["version"], version)
        self.assertEqual(
            (CHART / "templates/aggregated-roles.yaml").read_bytes(),
            (CHART.parent / "base/aggregated-roles.yaml").read_bytes(),
        )

    def test_all_twenty_objects_and_four_non_release_managed_definitions(self):
        self.assertEqual(len(self.rendered), 20)
        definitions = {
            item["metadata"]["name"]
            for item in self.rendered
            if item["kind"] == "CustomResourceDefinition"
        }
        self.assertEqual(definitions, DEFINITION_NAMES)
        # Upstream crds/ are not release-managed templates or uninstall hooks.
        self.assertFalse(
            any(item["kind"] == "CustomResourceDefinition" for item in self.render())
        )
        installed_definitions = documents(
            subprocess.check_output(
                ["helm", "show", "crds", str(self.chart)], text=True
            )
        )
        self.assertEqual(
            {item["metadata"]["name"] for item in installed_definitions},
            DEFINITION_NAMES,
        )
        self.assertFalse(
            any(
                "helm.sh/hook" in item["metadata"].get("annotations", {})
                for item in self.rendered
            )
        )
        self.assertNotIn("Namespace", {item["kind"] for item in self.rendered})

    def test_platform_security_and_rbac_are_preserved(self):
        deployment = next(
            item for item in self.rendered if item["kind"] == "Deployment"
        )
        pod = deployment["spec"]["template"]["spec"]
        container = pod["containers"][0]
        self.assertEqual(
            pod["securityContext"]["seccompProfile"]["type"], "RuntimeDefault"
        )
        self.assertEqual(
            container["securityContext"]["seccompProfile"]["type"], "RuntimeDefault"
        )
        self.assertFalse(container["securityContext"]["allowPrivilegeEscalation"])
        self.assertTrue(container["securityContext"]["runAsNonRoot"])
        self.assertEqual(container["securityContext"]["capabilities"]["drop"], ["ALL"])
        self.assertIn(
            {"name": "ENABLE_INIT_CONTAINER_INJECTION", "value": "false"},
            container["env"],
        )
        role = next(
            item
            for item in self.rendered
            if item["kind"] == "ClusterRole"
            and item["metadata"]["name"] == "kubeflow-kuberay-admin"
        )
        self.assertNotIn("aggregationRule", role)
        self.assertEqual(role["rules"], [])

    def test_non_platform_namespace_is_rejected(self):
        result = subprocess.run(
            ["helm", "template", "kuberay-operator", str(self.chart), "-n", "default"],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("existing kubeflow namespace", result.stderr)

    def test_different_release_name_is_rejected(self):
        result = subprocess.run(
            ["helm", "template", "different", str(self.chart), "-n", "kubeflow"],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release name must be kuberay-operator", result.stderr)

    def test_upstream_image_override_does_not_change_selectors(self):
        changed = self.render("--set", "kuberay-operator.image.tag=example")
        previous = next(item for item in self.rendered if item["kind"] == "Deployment")
        current = next(item for item in changed if item["kind"] == "Deployment")
        self.assertEqual(previous["spec"]["selector"], current["spec"]["selector"])
        self.assertEqual(
            current["spec"]["template"]["spec"]["containers"][0]["image"],
            "quay.io/kuberay/operator:example",
        )


class RaySmokeOwnershipTest(unittest.TestCase):
    def run_smoke_failure(self, managed_by_helm):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            log = directory / "commands"
            commands = {
                "kubectl": """#!/usr/bin/env bash
printf 'kubectl %s\\n' "$*" >> "$COMMAND_LOG"
case "$*" in
  *'get raycluster kubeflow-raycluster'*) exit 1 ;;
  *'get pods'*) if [[ -e "$COMMAND_LOG.failed" ]]; then echo '{"items":[]}'; else echo '{"items":[{},{}]}'; fi ;;
  *'exec -i'*) cat >/dev/null; touch "$COMMAND_LOG.failed"; exit 42 ;;
esac
""",
                "kustomize": """#!/usr/bin/env bash
printf 'kustomize %s\\n' "$*" >> "$COMMAND_LOG"
echo 'apiVersion: v1'
""",
            }
            for name, body in commands.items():
                executable = directory / name
                executable.write_text(body)
                executable.chmod(0o755)
            result = subprocess.run(
                [
                    "bash",
                    str(ROOT / "experimental/ray/test.sh"),
                    "kubeflow-user-example-com",
                ],
                env={
                    **os.environ,
                    "PATH": f"{directory}:{os.environ['PATH']}",
                    "COMMAND_LOG": str(log),
                    "RAY_MANAGED_BY_HELM": managed_by_helm,
                },
                capture_output=True,
                text=True,
            )
            return result, log.read_text() if log.exists() else ""

    def test_helm_failure_cleans_its_fixture_without_deleting_operator_or_definitions(
        self,
    ):
        result, commands = self.run_smoke_failure("true")
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("delete -f raycluster_example.yaml", commands)
        self.assertIn(
            "get pods -l ray.io/cluster=kubeflow-raycluster -o json", commands
        )
        self.assertNotIn("kustomize", commands)
        self.assertNotIn("kubectl -n kubeflow delete", commands)

    def test_legacy_path_still_installs_and_removes_its_operator(self):
        result, commands = self.run_smoke_failure("false")
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(
            commands.count("kustomize build kuberay-operator/overlays/kubeflow"), 2
        )
        self.assertIn("kubectl -n kubeflow delete", commands)

    def test_invalid_ownership_mode_is_rejected_before_cluster_access(self):
        result, commands = self.run_smoke_failure("unexpected")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(commands, "")


if __name__ == "__main__":
    unittest.main()
