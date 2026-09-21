#!/usr/bin/env python3
"""Knative Serving ownership, bootstrap and literal-payload behavior."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "common/knative/knative-serving/helm"


def render(*arguments, chart=CHART, namespace="kubeflow"):
    return subprocess.run(
        [
            "helm",
            "template",
            "knative-serving",
            str(chart),
            "-n",
            namespace,
            *arguments,
        ],
        capture_output=True,
        text=True,
    )


def objects(result):
    if result.returncode:
        raise AssertionError(result.stderr)
    return [item for item in yaml.safe_load_all(result.stdout) if item]


class ServingChartTest(unittest.TestCase):
    def test_installer_completes_or_resumes_without_pruning_complete_releases(self):
        # Exercise the real shell control flow without accessing a cluster.
        for previous in ("absent", "definitions", "controllers", "complete"):
            with self.subTest(
                previous=previous
            ), tempfile.TemporaryDirectory() as directory:
                temporary = Path(directory)
                log = temporary / "commands"
                command = temporary / "command"
                command.write_text(
                    "#!/usr/bin/env python3\n"
                    "import json, os, pathlib, sys\n"
                    "name=pathlib.Path(sys.argv[0]).name; args=sys.argv[1:]\n"
                    "with open(os.environ['COMMAND_LOG'], 'a') as stream: stream.write(json.dumps([name,*args])+'\\n')\n"
                    "if name=='helm' and args[0]=='status': sys.exit(os.environ['PREVIOUS_PHASE']=='absent')\n"
                    "if name=='helm' and args[:2]==['get','values']: print(json.dumps({'installation': {'phase':os.environ['PREVIOUS_PHASE']}}))\n"
                )
                command.chmod(0o755)
                for name in ("helm", "kubectl"):
                    (temporary / name).symlink_to(command)
                result = subprocess.run(
                    ["bash", str(ROOT / "tests/knative_serving_helm_install.sh")],
                    cwd=ROOT,
                    env={
                        **os.environ,
                        "PATH": str(temporary) + os.pathsep + os.environ["PATH"],
                        "COMMAND_LOG": str(log),
                        "PREVIOUS_PHASE": previous,
                    },
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                import json

                commands = [json.loads(line) for line in log.read_text().splitlines()]
                upgrades = [c for c in commands if c[:2] == ["helm", "upgrade"]]
                self.assertIn("installation.phase=complete", upgrades[-1])
                self.assertIn("--reset-values", upgrades[-1])
                self.assertEqual(
                    any("installation.phase=controllers" in c for c in upgrades),
                    previous != "complete",
                )
                self.assertEqual(
                    any(c[:2] == ["helm", "install"] for c in commands),
                    previous == "absent",
                )

    def test_bootstrap_phases_own_each_object_once(self):
        complete = objects(render())
        definitions = objects(render("--set", "installation.phase=definitions"))
        controllers = objects(render("--set", "installation.phase=controllers"))
        self.assertEqual(len(complete), 81)
        self.assertEqual(len(definitions), 13)
        self.assertEqual(len(controllers), 79)
        self.assertEqual(
            {r["kind"] for r in definitions}, {"Namespace", "CustomResourceDefinition"}
        )
        self.assertFalse({"Image", "Certificate"} & {r["kind"] for r in controllers})
        for subset in (complete, definitions, controllers):
            identities = {
                (
                    r["apiVersion"],
                    r["kind"],
                    r["metadata"].get("namespace"),
                    r["metadata"]["name"],
                )
                for r in subset
            }
            self.assertEqual(len(identities), len(subset))

    def test_retention_and_namespace_labels(self):
        resources = objects(render())
        retained = [
            r
            for r in resources
            if r["kind"] in ("Namespace", "CustomResourceDefinition")
        ]
        self.assertEqual(len(retained), 13)
        for resource in retained:
            self.assertEqual(
                resource["metadata"]["annotations"]["helm.sh/resource-policy"], "keep"
            )
        namespace = next(r for r in resources if r["kind"] == "Namespace")
        self.assertEqual(namespace["metadata"]["name"], "knative-serving")
        self.assertEqual(namespace["metadata"]["labels"]["istio-injection"], "enabled")
        self.assertEqual(
            namespace["metadata"]["labels"]["pod-security.kubernetes.io/enforce"],
            "restricted",
        )

    def test_queue_proxy_image_matches_generated_configuration(self):
        resources = objects(render())
        image = next(r["spec"]["image"] for r in resources if r["kind"] == "Image")
        configuration = next(
            r
            for r in resources
            if r["kind"] == "ConfigMap" and r["metadata"]["name"] == "config-deployment"
        )
        self.assertEqual(configuration["data"]["queue-sidecar-image"], image)

    def test_invalid_namespace_scenario_and_phase_fail(self):
        self.assertNotEqual(render(namespace="knative-serving").returncode, 0)
        self.assertNotEqual(render("--set", "scenario=other").returncode, 0)
        self.assertNotEqual(render("--set", "installation.phase=other").returncode, 0)

    def test_missing_payload_and_literal_template_content(self):
        with tempfile.TemporaryDirectory() as temporary:
            chart = Path(temporary) / "chart"
            shutil.copytree(CHART, chart)
            payload = chart / "manifests/platform-resources.yaml"
            original = payload.read_text()
            for text in ("", "# comment only\n"):
                payload.write_text(text)
                self.assertIn("missing or empty", render(chart=chart).stderr)
            payload.unlink()
            self.assertIn("missing or empty", render(chart=chart).stderr)
            payload.write_text(
                original
                + '\n---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: literal\ndata:\n  value: "{{ .Values.neverEvaluate }}"\n'
            )
            self.assertIn("{{ .Values.neverEvaluate }}", render(chart=chart).stdout)


if __name__ == "__main__":
    unittest.main()
