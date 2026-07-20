#!/usr/bin/env python3

import copy
import importlib.util
import unittest
from pathlib import Path

import yaml

MODULE_PATH = Path(__file__).with_name("helm_kustomize_compare.py")
WORKFLOW_PATH = (
    Path(__file__).resolve().parents[1]
    / ".github/workflows/helm-kustomize-comparison.yml"
)
MODULE_SPEC = importlib.util.spec_from_file_location(
    "helm_kustomize_compare", MODULE_PATH
)
helm_kustomize_compare = importlib.util.module_from_spec(MODULE_SPEC)
MODULE_SPEC.loader.exec_module(helm_kustomize_compare)


def dex_deployment_manifest():
    return {
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {
            "name": "dex",
            "namespace": "auth",
            "annotations": {
                "checksum/top-level": "keep-top-level-checksum",
                "example.com/top-level": "keep-top-level-annotation",
            },
        },
        "spec": {
            "template": {
                "metadata": {
                    "annotations": {
                        "checksum/config": "ignore-config-checksum",
                        "checksum/oidc-client": "ignore-client-checksum",
                        "checksum/passwords": "ignore-passwords-checksum",
                        "checksum/custom": "keep-custom-checksum",
                        "example.com/pod-template": "keep-pod-annotation",
                    }
                }
            }
        },
    }


class NormalizeManifestTest(unittest.TestCase):
    def test_dex_config_map_compares_embedded_yaml_semantically(self):
        unquoted_username = {
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {"name": "dex", "namespace": "auth"},
            "data": {"config.yaml": "staticPasswords:\n- username: user\n"},
        }
        quoted_username = copy.deepcopy(unquoted_username)
        quoted_username["data"][
            "config.yaml"
        ] = 'staticPasswords:\n- username: "user"\n'

        self.assertEqual(
            helm_kustomize_compare.normalize_manifest(
                unquoted_username,
                component="dex",
            ),
            helm_kustomize_compare.normalize_manifest(
                quoted_username,
                component="dex",
            ),
        )

    def test_dex_config_map_yaml_parsing_is_scoped_to_exact_resource(self):
        manifest = {
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {"name": "dex", "namespace": "auth"},
            "data": {"config.yaml": "staticPasswords:\n- username: user\n"},
        }
        outside_scope = {
            "different component": (manifest, "katib"),
            "different kind": ({**manifest, "kind": "Secret"}, "dex"),
            "different name": (
                {
                    **manifest,
                    "metadata": {**manifest["metadata"], "name": "dex-canary"},
                },
                "dex",
            ),
            "different namespace": (
                {
                    **manifest,
                    "metadata": {**manifest["metadata"], "namespace": "other"},
                },
                "dex",
            ),
        }

        for case_name, (candidate, component) in outside_scope.items():
            with self.subTest(case_name=case_name):
                normalized = helm_kustomize_compare.normalize_manifest(
                    copy.deepcopy(candidate),
                    component=component,
                )
                self.assertIsInstance(normalized["data"]["config.yaml"], str)

    def test_dex_config_map_rejects_malformed_embedded_yaml(self):
        malformed_config_map = {
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {"name": "dex", "namespace": "auth"},
            "data": {"config.yaml": "staticPasswords: [\n"},
        }

        with self.assertRaises(yaml.YAMLError):
            helm_kustomize_compare.normalize_manifest(
                malformed_config_map,
                component="dex",
            )

    def test_dex_ignores_only_known_rollout_checksum_annotations(self):
        manifest = dex_deployment_manifest()

        normalized = helm_kustomize_compare.normalize_manifest(
            copy.deepcopy(manifest), component="dex"
        )

        self.assertEqual(
            normalized["metadata"]["annotations"],
            manifest["metadata"]["annotations"],
        )
        self.assertEqual(
            normalized["spec"]["template"]["metadata"]["annotations"],
            {
                "checksum/custom": "keep-custom-checksum",
                "example.com/pod-template": "keep-pod-annotation",
            },
        )

    def test_dex_ignores_rollout_checksums_only_for_auth_namespace_deployment(self):
        manifest = dex_deployment_manifest()
        workloads_outside_dex_comparison_scope = {
            "different component": (manifest, "katib"),
            "different kind": ({**manifest, "kind": "StatefulSet"}, "dex"),
            "different name": (
                {
                    **manifest,
                    "metadata": {**manifest["metadata"], "name": "dex-canary"},
                },
                "dex",
            ),
            "different namespace": (
                {
                    **manifest,
                    "metadata": {**manifest["metadata"], "namespace": "other"},
                },
                "dex",
            ),
        }

        for case_name, (
            workload,
            component,
        ) in workloads_outside_dex_comparison_scope.items():
            with self.subTest(case_name=case_name):
                normalized_workload = helm_kustomize_compare.normalize_manifest(
                    copy.deepcopy(workload), component=component
                )
                self.assertEqual(
                    normalized_workload["spec"]["template"]["metadata"]["annotations"],
                    manifest["spec"]["template"]["metadata"]["annotations"],
                )


class ComparisonWorkflowTest(unittest.TestCase):
    def test_dex_checks_run_in_enforcing_job(self):
        workflow = yaml.safe_load(WORKFLOW_PATH.read_text())
        unit_test_job = workflow["jobs"]["validate-dex-unit-tests"]
        steps_by_name = {step["name"]: step for step in unit_test_job["steps"]}
        run_commands = "\n".join(step.get("run", "") for step in unit_test_job["steps"])

        self.assertFalse(unit_test_job.get("continue-on-error", False))
        self.assertIn("./tests/kustomize_install.sh", run_commands)
        self.assertIn("python tests/test_helm_kustomize_compare.py", run_commands)
        self.assertIn("python tests/test_dex_helm_rollout_checksums.py", run_commands)
        self.assertIn("./tests/helm_kustomize_compare_all.sh dex", run_commands)
        for step_name in [
            "Install Kustomize",
            "Test Helm comparison normalization",
            "Test Dex Helm behavior",
            "Compare Dex Helm and Kustomize manifests",
        ]:
            with self.subTest(step_name=step_name):
                test_step = steps_by_name[step_name]
                self.assertFalse(test_step.get("continue-on-error", False))
                self.assertNotIn("if", test_step)


if __name__ == "__main__":
    unittest.main()
