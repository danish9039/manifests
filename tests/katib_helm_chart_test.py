#!/usr/bin/env python3
"""Behaviour of the Katib Helm chart."""

import re
import subprocess
import unittest

from pathlib import Path

import yaml

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
CHART_PATH = REPOSITORY_ROOT / "applications/katib/helm"
UPSTREAM_DEFINITIONS_PATH = (
    REPOSITORY_ROOT / "applications/katib/upstream/components/crd"
)
SYNCHRONIZATION_SCRIPT = REPOSITORY_ROOT / "scripts/synchronize-katib-manifests.sh"
RELEASE_NAMESPACE = "kubeflow"
PLATFORM_VALUES_FILE = "ci/values-kubeflow.yaml"
VALUES_FILES = [
    "ci/values-cert-manager.yaml",
    "ci/values-enterprise.yaml",
    "ci/values-external-db.yaml",
    "ci/values-kubeflow.yaml",
    "ci/values-leader-election.yaml",
    "ci/values-openshift.yaml",
    "ci/values-postgres.yaml",
    "ci/values-production.yaml",
    "ci/values-standalone.yaml",
]
# Every field that differs between two renders of the same input. The chart
# generates these values when the administrator supplies none, so an upgrade
# with such values replaces them. None selects the chart defaults.
RANDOM_FIELDS = {
    None: {
        ("Secret", "katib-mysql-secrets", "data", "MYSQL_PASSWORD"),
        ("Secret", "katib-webhook-cert", "data", "tls.crt"),
        ("Secret", "katib-webhook-cert", "data", "tls.key"),
    },
    "ci/values-enterprise.yaml": {
        ("Secret", "katib-mysql-secrets", "data", "MYSQL_PASSWORD"),
    },
    "ci/values-production.yaml": {
        ("Secret", "katib-postgres-secrets", "data", "POSTGRES_PASSWORD"),
    },
}
# The aggregation controller owns the rules of a ClusterRole that has an
# aggregationRule. A manifest that ships the field, even as an empty list, claims
# it with server-side apply, and the next helm upgrade conflicts with that
# controller.
AGGREGATED_ROLE = "kubeflow-katib-admin"
AGGREGATED_ROLE_LABELS = {
    "rbac.authorization.kubeflow.org/aggregate-to-kubeflow-admin": "true",
}
AGGREGATED_ROLE_SELECTORS = [
    {
        "matchLabels": {
            "rbac.authorization.kubeflow.org/aggregate-to-kubeflow-katib-admin": "true",
        }
    }
]
# The chart labels its CustomResourceDefinitions; upstream does not.
DEFINITION_LABELS_ALLOWED_TO_DIFFER = {
    "app.kubernetes.io/name",
    "app.kubernetes.io/component",
}


def render_chart(values_file=None):
    arguments = (
        [] if values_file is None else ["--values", str(CHART_PATH / values_file)]
    )
    return subprocess.run(
        [
            "helm",
            "template",
            "katib",
            str(CHART_PATH),
            "--namespace",
            RELEASE_NAMESPACE,
            "--include-crds",
            *arguments,
        ],
        capture_output=True,
        text=True,
    )


def load_manifests(rendered):
    return [document for document in yaml.safe_load_all(rendered) if document]


def flatten(value, path=()):
    if isinstance(value, dict):
        for key, child in value.items():
            yield from flatten(child, path + (key,))
    elif isinstance(value, list):
        for position, child in enumerate(value):
            yield from flatten(child, path + (position,))
    else:
        yield path, value


def differing_fields(first_render, second_render):
    first, second = (
        {
            (manifest["kind"], manifest["metadata"]["name"]): dict(flatten(manifest))
            for manifest in load_manifests(rendered)
        }
        for rendered in (first_render, second_render)
    )
    if first.keys() != second.keys():
        raise AssertionError("Two renders of the same input differ in resources.")
    return {
        identity + path
        for identity in first
        for path in first[identity].keys() | second[identity].keys()
        if first[identity].get(path) != second[identity].get(path)
    }


def aggregated_cluster_roles(rendered):
    return {
        manifest["metadata"]["name"]: manifest
        for manifest in load_manifests(rendered)
        if manifest["kind"] == "ClusterRole"
        and manifest["apiVersion"].startswith("rbac.authorization.k8s.io/")
        and "aggregationRule" in manifest
    }


def without_allowed_labels(definition):
    metadata = dict(definition["metadata"])
    labels = {
        key: value
        for key, value in metadata.pop("labels", {}).items()
        if key not in DEFINITION_LABELS_ALLOWED_TO_DIFFER
    }
    if labels:
        metadata["labels"] = labels
    return {**definition, "metadata": metadata}


def load_definitions(directory):
    definitions = {}
    for definition_file in sorted(directory.glob("*.yaml")):
        for document in load_manifests(definition_file.read_text()):
            if document["kind"] == "CustomResourceDefinition":
                definitions[document["metadata"]["name"]] = document
    return definitions


class KatibHelmChartTest(unittest.TestCase):
    def test_values_file_list_is_complete(self):
        self.assertEqual(
            sorted(f"ci/{path.name}" for path in CHART_PATH.glob("ci/values-*.yaml")),
            VALUES_FILES,
        )

    def test_every_values_file_renders(self):
        for values_file in VALUES_FILES:
            with self.subTest(values_file=values_file):
                result = render_chart(values_file)

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(load_manifests(result.stdout))

    def test_pinned_versions_agree(self):
        commit = re.search(
            r'^COMMIT="([^"]+)"$', SYNCHRONIZATION_SCRIPT.read_text(), re.MULTILINE
        ).group(1)
        chart = yaml.safe_load((CHART_PATH / "Chart.yaml").read_text())
        values = yaml.safe_load((CHART_PATH / "values.yaml").read_text())

        self.assertEqual(chart["appVersion"], commit)
        self.assertEqual(values["global"]["imageTag"], commit)
        for values_file in VALUES_FILES:
            scenario_values = yaml.safe_load((CHART_PATH / values_file).read_text())
            if "imageTag" in scenario_values.get("global", {}):
                with self.subTest(values_file=values_file):
                    self.assertEqual(scenario_values["global"]["imageTag"], commit)

    def test_platform_scenario_renders_the_same_bytes_twice(self):
        first = render_chart(PLATFORM_VALUES_FILE)
        second = render_chart(PLATFORM_VALUES_FILE)

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(first.stdout, second.stdout)

    def test_random_fields_are_exactly_the_recorded_inventory(self):
        for values_file in [None, *VALUES_FILES]:
            with self.subTest(values_file=values_file):
                first = render_chart(values_file)
                second = render_chart(values_file)

                self.assertEqual(first.returncode, 0, first.stderr)
                self.assertEqual(second.returncode, 0, second.stderr)
                self.assertEqual(
                    differing_fields(first.stdout, second.stdout),
                    RANDOM_FIELDS.get(values_file, set()),
                )

    def test_definitions_equal_upstream_except_two_labels(self):
        chart_definitions = load_definitions(CHART_PATH / "crds")
        upstream_definitions = load_definitions(UPSTREAM_DEFINITIONS_PATH)

        self.assertEqual(
            sorted(chart_definitions),
            [
                "experiments.kubeflow.org",
                "suggestions.kubeflow.org",
                "trials.kubeflow.org",
            ],
        )
        self.assertEqual(chart_definitions.keys(), upstream_definitions.keys())
        for name, chart_definition in chart_definitions.items():
            with self.subTest(definition=name):
                self.assertEqual(
                    without_allowed_labels(chart_definition),
                    without_allowed_labels(upstream_definitions[name]),
                )

    def test_aggregated_cluster_roles_omit_rules(self):
        for values_file in [None, *VALUES_FILES]:
            with self.subTest(values_file=values_file):
                result = render_chart(values_file)

                self.assertEqual(result.returncode, 0, result.stderr)
                for name, role in aggregated_cluster_roles(result.stdout).items():
                    self.assertNotIn("rules", role, name)

        platform = render_chart(PLATFORM_VALUES_FILE)

        self.assertEqual(platform.returncode, 0, platform.stderr)
        platform_roles = aggregated_cluster_roles(platform.stdout)
        self.assertIn(AGGREGATED_ROLE, platform_roles)
        self.assertEqual(
            platform_roles[AGGREGATED_ROLE]["metadata"]["labels"],
            AGGREGATED_ROLE_LABELS,
        )
        self.assertEqual(
            platform_roles[AGGREGATED_ROLE]["aggregationRule"],
            {"clusterRoleSelectors": AGGREGATED_ROLE_SELECTORS},
        )


if __name__ == "__main__":
    unittest.main()
