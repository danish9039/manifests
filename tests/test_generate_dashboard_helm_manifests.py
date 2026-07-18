#!/usr/bin/env python3

import copy
import importlib.util
import shutil
import subprocess
import tarfile
import tempfile
import unittest

from pathlib import Path
from unittest import mock

from ruamel.yaml import YAML

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
GENERATOR_PATH = REPOSITORY_ROOT / "scripts/generate-dashboard-helm-manifests.py"
CHART_PATH = REPOSITORY_ROOT / "applications/dashboard/helm"


def load_generator_module():
    spec = importlib.util.spec_from_file_location(
        "generate_dashboard_helm_manifests", GENERATOR_PATH
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DashboardHelmManifestGeneratorTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.generator = load_generator_module()
        cls.yaml = YAML(typ="safe")

    def resource(
        self,
        name,
        application_name=None,
        kind="ConfigMap",
        api_version="v1",
        namespace="kubeflow",
    ):
        metadata = {"name": name}
        if namespace is not None:
            metadata["namespace"] = namespace
        if application_name is not None:
            metadata["labels"] = {
                "app.kubernetes.io/name": application_name,
            }
        return {
            "apiVersion": api_version,
            "kind": kind,
            "metadata": metadata,
        }

    def complete_resource_set(self):
        return [
            self.resource("dashboard", "centraldashboard"),
            self.resource(
                "poddefaults.kubeflow.org",
                "poddefaults-webhook",
                kind="CustomResourceDefinition",
                api_version="apiextensions.k8s.io/v1",
                namespace=None,
            ),
            self.resource("poddefaults-webhook-service", "poddefaults-webhook"),
            self.resource(
                "profiles.kubeflow.org",
                "profile-controller",
                kind="CustomResourceDefinition",
                api_version="apiextensions.k8s.io/v1",
                namespace=None,
            ),
            self.resource("profiles-deployment", "profile-controller"),
        ]

    def test_resource_identity_contains_api_kind_namespace_and_name(self):
        resource = self.resource("dashboard", "centraldashboard")

        identity = self.generator.resource_identity(resource)

        self.assertEqual(identity, ("v1", "ConfigMap", "kubeflow", "dashboard"))

    def test_missing_identity_fields_fail(self):
        valid_resource = self.resource("dashboard", "centraldashboard")
        invalid_resources = []
        for field_path in [
            ("apiVersion",),
            ("kind",),
            ("metadata",),
            ("metadata", "name"),
        ]:
            resource = copy.deepcopy(valid_resource)
            if len(field_path) == 1:
                del resource[field_path[0]]
            else:
                del resource[field_path[0]][field_path[1]]
            invalid_resources.append(resource)

        for resource in invalid_resources:
            with self.subTest(resource=resource):
                with self.assertRaisesRegex(ValueError, "identity"):
                    self.generator.resource_identity(resource)

    def test_duplicate_resource_identities_fail(self):
        resource = self.resource("dashboard", "centraldashboard")

        with self.assertRaisesRegex(ValueError, "duplicate resource identity"):
            self.generator.generate_payload_contents(
                [resource, copy.deepcopy(resource)]
            )

    def test_duplicate_resource_across_api_versions_fails(self):
        stable_resource = self.resource(
            "dashboard",
            "centraldashboard",
            kind="Deployment",
            api_version="apps/v1",
        )
        beta_resource = copy.deepcopy(stable_resource)
        beta_resource["apiVersion"] = "apps/v1beta1"

        with self.assertRaisesRegex(ValueError, "duplicate resource identity"):
            self.generator.generate_payload_contents([stable_resource, beta_resource])

    def test_crd_retention_is_added_without_mutating_input(self):
        resources = self.complete_resource_set()
        original_resources = copy.deepcopy(resources)

        payloads = self.generator.generate_payload_contents(resources)
        poddefaults_crd = next(
            self.yaml.load_all(payloads["poddefaults-webhook-crds.yaml"])
        )

        self.assertEqual(
            poddefaults_crd["metadata"]["annotations"]["helm.sh/resource-policy"],
            "keep",
        )
        self.assertEqual(resources, original_resources)

    def test_non_crd_resources_are_not_changed(self):
        resources = self.complete_resource_set()
        original_dashboard = copy.deepcopy(resources[0])

        payloads = self.generator.generate_payload_contents(resources)
        rendered_dashboard = next(
            self.yaml.load_all(payloads["central-dashboard-resources.yaml"])
        )

        self.assertEqual(rendered_dashboard, original_dashboard)

    def test_upstream_block_scalar_style_is_preserved(self):
        rendered_yaml = (
            "apiVersion: v1\n"
            "kind: ConfigMap\n"
            "metadata:\n"
            "  name: dashboard\n"
            "  namespace: kubeflow\n"
            "  labels:\n"
            "    app.kubernetes.io/name: centraldashboard\n"
            "data:\n"
            "  links: |-\n"
            "    {\n"
            '      "menuLinks": []\n'
            "    }\n"
        )
        dashboard_resource = self.generator.parse_resources(rendered_yaml)[0]
        resources = self.complete_resource_set()
        resources[0] = dashboard_resource

        payloads = self.generator.generate_payload_contents(resources)

        self.assertIn(
            "  links: |-\n    {\n",
            payloads["central-dashboard-resources.yaml"],
        )

    def test_every_resource_matches_exactly_one_component(self):
        payloads = self.generator.generate_payload_contents(
            self.complete_resource_set()
        )

        self.assertEqual(
            set(payloads),
            {
                "central-dashboard-resources.yaml",
                "poddefaults-webhook-crds.yaml",
                "poddefaults-webhook-resources.yaml",
                "profile-controller-crds.yaml",
                "profile-controller-resources.yaml",
            },
        )

    def test_unmatched_resource_fails(self):
        resource = self.resource("unknown-resource")

        with self.assertRaisesRegex(ValueError, "does not match any component"):
            self.generator.generate_payload_contents([resource])

    def test_resource_matching_multiple_components_fails(self):
        resource = self.resource(
            "profiles-config-deadbeef12",
            application_name="centraldashboard",
        )

        with self.assertRaisesRegex(ValueError, "matches multiple components"):
            self.generator.generate_payload_contents([resource])

    def test_generated_name_prefix_fallback_is_classified(self):
        resource = self.resource("profiles-config-deadbeef12")

        component = self.generator.classify_resource(resource)

        self.assertEqual(component, "profile-controller")

    def test_generated_name_prefix_fallback_requires_expected_scope(self):
        resource = self.resource(
            "profiles-config-deadbeef12",
            namespace="unrelated-namespace",
        )

        with self.assertRaisesRegex(ValueError, "does not match any component"):
            self.generator.classify_resource(resource)

    def test_generated_name_prefix_fallback_rejects_invalid_hash(self):
        resource = self.resource("profiles-config-not-a-kustomize-hash")

        with self.assertRaisesRegex(ValueError, "does not match any component"):
            self.generator.classify_resource(resource)

    def test_generated_name_prefix_does_not_override_unknown_label(self):
        resource = self.resource(
            "profiles-config-deadbeef12",
            application_name="unknown-component",
        )

        with self.assertRaisesRegex(ValueError, "unknown application label"):
            self.generator.classify_resource(resource)

    def test_payload_headers_identify_source_and_regeneration_command(self):
        payloads = self.generator.generate_payload_contents(
            self.complete_resource_set()
        )

        for payload in payloads.values():
            with self.subTest(payload=payload[:100]):
                self.assertTrue(
                    payload.startswith(
                        "# Code generated by "
                        "scripts/generate-dashboard-helm-manifests.py. DO NOT EDIT.\n"
                        "# Source: kustomize build "
                        "applications/dashboard/helm/kustomize\n"
                        "# Regenerate with: KUBEFLOW_SYNCHRONIZE_NO_COMMIT=true "
                        "./scripts/synchronize-dashboard-manifests.sh\n"
                    )
                )

    def test_failed_atomic_replacement_restores_previous_directory(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            output_directory = Path(temporary_directory) / "manifests"
            output_directory.mkdir()
            existing_payload = output_directory / "existing.yaml"
            existing_payload.write_text("existing\n")
            original_replace = self.generator.os.replace
            replacement_attempts = 0

            def fail_new_directory_replacement(source, destination):
                nonlocal replacement_attempts
                if Path(destination) == output_directory:
                    replacement_attempts += 1
                    if replacement_attempts == 1:
                        raise OSError("simulated replacement failure")
                return original_replace(source, destination)

            with mock.patch.object(
                self.generator.os,
                "replace",
                side_effect=fail_new_directory_replacement,
            ):
                with self.assertRaisesRegex(OSError, "simulated replacement failure"):
                    self.generator.write_payloads_atomically(
                        output_directory,
                        {"replacement.yaml": "replacement\n"},
                    )

            self.assertEqual(existing_payload.read_text(), "existing\n")
            self.assertFalse((output_directory / "replacement.yaml").exists())

    def test_successful_replacement_removes_stale_files(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            output_directory = Path(temporary_directory) / "manifests"
            output_directory.mkdir()
            (output_directory / "stale.yaml").write_text("stale\n")

            self.generator.write_payloads_atomically(
                output_directory,
                {"current.yaml": "current\n"},
            )

            self.assertFalse((output_directory / "stale.yaml").exists())
            self.assertEqual(
                (output_directory / "current.yaml").read_text(),
                "current\n",
            )

    def test_generation_is_byte_for_byte_deterministic(self):
        resources = self.complete_resource_set()

        first_payloads = self.generator.generate_payload_contents(resources)
        second_payloads = self.generator.generate_payload_contents(resources)

        self.assertEqual(first_payloads, second_payloads)

    def test_combined_kustomize_path_is_built_once(self):
        yaml = YAML()
        with tempfile.TemporaryDirectory() as temporary_directory:
            repository_root = Path(temporary_directory)
            render_path = repository_root / "render.yaml"
            with render_path.open("w") as stream:
                yaml.dump_all(self.complete_resource_set(), stream)
            completed_process = subprocess.CompletedProcess(
                args=[],
                returncode=0,
                stdout=render_path.read_text(),
                stderr="",
            )

            with mock.patch.object(
                self.generator.subprocess,
                "run",
                return_value=completed_process,
            ) as run:
                self.generator.generate_dashboard_manifests(repository_root)

            run.assert_called_once()
            self.assertEqual(
                run.call_args.args[0],
                [
                    "kustomize",
                    "build",
                    "applications/dashboard/helm/kustomize",
                ],
            )

    def test_literal_helm_template_expression_remains_literal(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            chart_directory = Path(temporary_directory) / "chart"
            shutil.copytree(CHART_PATH, chart_directory)
            payload = chart_directory / "manifests/central-dashboard-resources.yaml"
            with payload.open("a") as stream:
                stream.write(
                    "---\n"
                    "apiVersion: v1\n"
                    "kind: ConfigMap\n"
                    "metadata:\n"
                    "  name: literal-template-expression\n"
                    "data:\n"
                    '  value: "{{ upstream.value }}"\n'
                )

            result = subprocess.run(
                ["helm", "template", "kubeflow-dashboard", str(chart_directory)],
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('value: "{{ upstream.value }}"', result.stdout)

    def test_missing_or_empty_required_payload_fails_helm_render(self):
        for payload_state in ["missing", "empty", "comments", "separator"]:
            with self.subTest(payload_state=payload_state):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    chart_directory = Path(temporary_directory) / "chart"
                    shutil.copytree(CHART_PATH, chart_directory)
                    payload = (
                        chart_directory / "manifests/central-dashboard-resources.yaml"
                    )
                    if payload_state == "missing":
                        payload.unlink()
                    elif payload_state == "empty":
                        payload.write_text("")
                    elif payload_state == "comments":
                        payload.write_text("# generated payload\n")
                    else:
                        payload.write_text("---\n")

                    result = subprocess.run(
                        [
                            "helm",
                            "template",
                            "kubeflow-dashboard",
                            str(chart_directory),
                        ],
                        capture_output=True,
                        text=True,
                    )

                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("missing or empty", result.stderr)

    def test_packaged_chart_contains_every_generated_payload(self):
        expected_payloads = {
            "kubeflow-dashboard/manifests/central-dashboard-resources.yaml",
            "kubeflow-dashboard/manifests/poddefaults-webhook-crds.yaml",
            "kubeflow-dashboard/manifests/poddefaults-webhook-resources.yaml",
            "kubeflow-dashboard/manifests/profile-controller-crds.yaml",
            "kubeflow-dashboard/manifests/profile-controller-resources.yaml",
        }
        with tempfile.TemporaryDirectory() as temporary_directory:
            result = subprocess.run(
                [
                    "helm",
                    "package",
                    str(CHART_PATH),
                    "--destination",
                    temporary_directory,
                ],
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            package = next(Path(temporary_directory).glob("*.tgz"))
            with tarfile.open(package, "r:gz") as archive:
                packaged_files = set(archive.getnames())
            self.assertTrue(expected_payloads.issubset(packaged_files))


if __name__ == "__main__":
    unittest.main()
