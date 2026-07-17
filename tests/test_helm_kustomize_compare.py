#!/usr/bin/env python3

import copy
import importlib.util
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("helm_kustomize_compare.py")
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


if __name__ == "__main__":
    unittest.main()
