#!/usr/bin/env python3
"""Behaviour of the Kubeflow platform roles Helm chart."""

import subprocess
import unittest

from pathlib import Path

import yaml

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
CHART_PATH = REPOSITORY_ROOT / "common/kubeflow-roles/helm"
VALUES_FILE = CHART_PATH / "ci/values-default.yaml"
RELEASE_NAMESPACE = "kubeflow-system"

# Each aggregated role and the label that selects the roles it aggregates.
AGGREGATED_ROLES = {
    "kubeflow-admin": "rbac.authorization.kubeflow.org/aggregate-to-kubeflow-admin",
    "kubeflow-edit": "rbac.authorization.kubeflow.org/aggregate-to-kubeflow-edit",
    "kubeflow-view": "rbac.authorization.kubeflow.org/aggregate-to-kubeflow-view",
}
# Each contributing role and the aggregated role that must select it.
CONTRIBUTING_ROLES = {
    "kubeflow-kubernetes-admin": "kubeflow-admin",
    "kubeflow-kubernetes-edit": "kubeflow-edit",
    "kubeflow-kubernetes-view": "kubeflow-view",
}


def render_chart():
    return subprocess.run(
        [
            "helm",
            "template",
            "kubeflow-platform",
            str(CHART_PATH),
            "--namespace",
            RELEASE_NAMESPACE,
            "--values",
            str(VALUES_FILE),
        ],
        capture_output=True,
        text=True,
    )


class KubeflowRolesHelmChartTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        result = render_chart()
        if result.returncode != 0:
            raise AssertionError(result.stderr)
        cls.cluster_roles = {
            document["metadata"]["name"]: document
            for document in yaml.safe_load_all(result.stdout)
            if document and document["kind"] == "ClusterRole"
        }

    def test_aggregated_roles_omit_rules_and_keep_their_selectors(self):
        # The aggregation controller owns .rules. With Helm 4 server-side apply
        # an explicit empty list made every later upgrade conflict on that
        # field, and the parity comparison cannot tell an empty list from an
        # absent one, so only this render assertion catches a reintroduction.
        for name, label in AGGREGATED_ROLES.items():
            with self.subTest(role=name):
                role = self.cluster_roles[name]
                self.assertNotIn("rules", role)
                self.assertEqual(
                    role["aggregationRule"]["clusterRoleSelectors"],
                    [{"matchLabels": {label: "true"}}],
                )

    def test_contributing_roles_keep_their_permissions_and_labels(self):
        for name, aggregated_role in CONTRIBUTING_ROLES.items():
            with self.subTest(role=name):
                role = self.cluster_roles[name]
                self.assertNotIn("aggregationRule", role)
                self.assertTrue(role["rules"])
                self.assertEqual(
                    role["metadata"]["labels"][AGGREGATED_ROLES[aggregated_role]],
                    "true",
                )

    def test_the_chart_renders_no_other_cluster_role(self):
        self.assertEqual(
            set(self.cluster_roles),
            set(AGGREGATED_ROLES) | set(CONTRIBUTING_ROLES),
        )


if __name__ == "__main__":
    unittest.main()
