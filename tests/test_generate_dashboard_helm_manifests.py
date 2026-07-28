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

CRDS_PAYLOAD = "platform-crds.yaml"
RESOURCES_PAYLOAD = "platform-resources.yaml"
LINKS_DOCUMENT = "documents/dashboard-links.json"
SETTINGS_DOCUMENT = "documents/dashboard-settings.json"
NAMESPACE_LABELS_DOCUMENT = "documents/profile-namespace-labels.yaml"


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
        kind="ConfigMap",
        api_version="v1",
        namespace="kubeflow",
        data=None,
    ):
        metadata = {"name": name}
        if namespace is not None:
            metadata["namespace"] = namespace
        resource = {
            "apiVersion": api_version,
            "kind": kind,
            "metadata": metadata,
        }
        if data is not None:
            resource["data"] = data
        return resource

    def hand_written_resources(self):
        """The resources the chart renders from hand-written templates."""
        return [
            self.resource("dashboard", kind="Deployment", api_version="apps/v1"),
            self.resource(
                "poddefaults-webhook-deployment",
                kind="Deployment",
                api_version="apps/v1",
            ),
            self.resource(
                "profiles-deployment", kind="Deployment", api_version="apps/v1"
            ),
            self.resource(
                "dashboard-config",
                data={"links": '{"menuLinks": []}', "settings": "{}"},
            ),
            self.resource("dashboard-parameters-deadbeef12", data={"A": "b"}),
            self.resource("profiles-config-deadbeef12", data={"ADMIN": ""}),
            self.resource(
                "profiles-namespace-labels-data-deadbeef12",
                data={"namespace-labels.yaml": "key: value"},
            ),
        ]

    def complete_resource_set(self):
        return self.hand_written_resources() + [
            self.resource(
                "poddefaults.kubeflow.org",
                kind="CustomResourceDefinition",
                api_version="apiextensions.k8s.io/v1",
                namespace=None,
            ),
            self.resource(
                "profiles.kubeflow.org",
                kind="CustomResourceDefinition",
                api_version="apiextensions.k8s.io/v1",
                namespace=None,
            ),
            self.resource("poddefaults-webhook-service"),
        ]

    def test_resource_identity_contains_api_kind_namespace_and_name(self):
        resource = self.resource("dashboard-config")

        identity = self.generator.resource_identity(resource)

        self.assertEqual(identity, ("v1", "ConfigMap", "kubeflow", "dashboard-config"))

    def test_missing_identity_fields_fail(self):
        valid_resource = self.resource("dashboard-config")
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
            with self.subTest(field_path=field_path):
                with self.assertRaisesRegex(ValueError, "identity"):
                    self.generator.resource_identity(resource)

    def test_duplicate_resource_identities_fail(self):
        resources = self.complete_resource_set()
        resources.append(copy.deepcopy(resources[-1]))

        with self.assertRaisesRegex(ValueError, "duplicate resource identity"):
            self.generator.generate_payload_contents(resources)

    def test_duplicate_resource_across_api_versions_fails(self):
        resources = self.complete_resource_set()
        beta_resource = copy.deepcopy(resources[0])
        beta_resource["apiVersion"] = "apps/v1beta1"
        resources.append(beta_resource)

        with self.assertRaisesRegex(ValueError, "duplicate resource identity"):
            self.generator.generate_payload_contents(resources)

    def test_payloads_are_split_only_by_custom_resource_definition(self):
        payloads = self.generator.generate_payload_contents(
            self.complete_resource_set()
        )

        self.assertEqual(
            set(payloads),
            {
                CRDS_PAYLOAD,
                RESOURCES_PAYLOAD,
                LINKS_DOCUMENT,
                SETTINGS_DOCUMENT,
                NAMESPACE_LABELS_DOCUMENT,
            },
        )

    def test_hand_written_resources_are_excluded_from_payloads(self):
        payloads = self.generator.generate_payload_contents(
            self.complete_resource_set()
        )
        rendered = payloads[CRDS_PAYLOAD] + payloads[RESOURCES_PAYLOAD]

        for resource in self.hand_written_resources():
            with self.subTest(name=resource["metadata"]["name"]):
                self.assertNotIn(
                    f"name: {resource['metadata']['name']}",
                    rendered,
                )

    def test_orphaned_hand_written_resource_fails(self):
        resources = [
            resource
            for resource in self.complete_resource_set()
            if resource["metadata"]["name"] != "dashboard-config"
        ]

        with self.assertRaisesRegex(ValueError, "orphaned"):
            self.generator.generate_payload_contents(resources)

    def test_generated_name_prefix_requires_a_valid_kustomize_hash(self):
        resources = self.complete_resource_set()
        for resource in resources:
            if resource["metadata"]["name"].startswith("profiles-config-"):
                resource["metadata"]["name"] = "profiles-config-not-a-hash"

        with self.assertRaisesRegex(ValueError, "orphaned"):
            self.generator.generate_payload_contents(resources)

    def test_crd_retention_is_added_without_mutating_input(self):
        resources = self.complete_resource_set()
        original_resources = copy.deepcopy(resources)

        payloads = self.generator.generate_payload_contents(resources)
        first_crd = next(self.yaml.load_all(payloads[CRDS_PAYLOAD]))

        self.assertEqual(
            first_crd["metadata"]["annotations"]["helm.sh/resource-policy"],
            "keep",
        )
        self.assertEqual(resources, original_resources)

    def test_non_crd_resources_are_not_changed(self):
        resources = self.complete_resource_set()
        expected = copy.deepcopy(resources[-1])

        payloads = self.generator.generate_payload_contents(resources)
        rendered = list(self.yaml.load_all(payloads[RESOURCES_PAYLOAD]))

        self.assertIn(expected, rendered)

    def test_upstream_block_scalar_style_is_preserved(self):
        rendered_yaml = (
            "apiVersion: v1\n"
            "kind: ConfigMap\n"
            "metadata:\n"
            "  name: poddefaults-webhook-service\n"
            "  namespace: kubeflow\n"
            "data:\n"
            "  links: |-\n"
            "    {\n"
            '      "menuLinks": []\n'
            "    }\n"
        )
        parsed = self.generator.parse_resources(rendered_yaml)[0]
        resources = self.complete_resource_set()
        resources[-1] = parsed

        payloads = self.generator.generate_payload_contents(resources)

        self.assertIn("  links: |-\n    {\n", payloads[RESOURCES_PAYLOAD])

    def test_documents_are_extracted_verbatim_with_a_trailing_newline(self):
        payloads = self.generator.generate_payload_contents(
            self.complete_resource_set()
        )

        self.assertEqual(payloads[LINKS_DOCUMENT], '{"menuLinks": []}\n')
        self.assertEqual(payloads[SETTINGS_DOCUMENT], "{}\n")
        self.assertEqual(payloads[NAMESPACE_LABELS_DOCUMENT], "key: value\n")

    def test_documents_carry_no_generated_header(self):
        payloads = self.generator.generate_payload_contents(
            self.complete_resource_set()
        )

        for document in [LINKS_DOCUMENT, SETTINGS_DOCUMENT]:
            with self.subTest(document=document):
                self.assertFalse(payloads[document].startswith("#"))

    def test_missing_document_data_key_fails(self):
        resources = self.complete_resource_set()
        for resource in resources:
            if resource["metadata"]["name"] == "dashboard-config":
                del resource["data"]["links"]

        with self.assertRaisesRegex(ValueError, "missing data key"):
            self.generator.generate_payload_contents(resources)

    def test_empty_document_data_key_fails(self):
        resources = self.complete_resource_set()
        for resource in resources:
            if resource["metadata"]["name"] == "dashboard-config":
                resource["data"]["links"] = "  "

        with self.assertRaisesRegex(ValueError, "empty"):
            self.generator.generate_payload_contents(resources)

    def test_payload_headers_identify_source_and_regeneration_command(self):
        payloads = self.generator.generate_payload_contents(
            self.complete_resource_set()
        )

        for payload_name in [CRDS_PAYLOAD, RESOURCES_PAYLOAD]:
            with self.subTest(payload=payload_name):
                self.assertTrue(
                    payloads[payload_name].startswith(
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
                {"current.yaml": "current\n", "documents/nested.json": "{}\n"},
            )

            self.assertFalse((output_directory / "stale.yaml").exists())
            self.assertEqual(
                (output_directory / "current.yaml").read_text(),
                "current\n",
            )
            self.assertEqual(
                (output_directory / "documents/nested.json").read_text(),
                "{}\n",
            )

    def test_payload_filename_must_not_escape_the_output_directory(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            output_directory = Path(temporary_directory) / "manifests"

            for filename in ["../escape.yaml", "a/b/c.yaml", "/absolute.yaml"]:
                with self.subTest(filename=filename):
                    with self.assertRaises(ValueError):
                        self.generator.write_payloads_atomically(
                            output_directory, {filename: "content\n"}
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
            payload = chart_directory / "manifests" / RESOURCES_PAYLOAD
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
                [
                    "helm",
                    "template",
                    "kubeflow-dashboard",
                    str(chart_directory),
                    "--namespace",
                    "kubeflow",
                ],
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
                    payload = chart_directory / "manifests" / RESOURCES_PAYLOAD
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
                            "--namespace",
                            "kubeflow",
                        ],
                        capture_output=True,
                        text=True,
                    )

                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("missing or empty", result.stderr)

    def test_missing_document_fails_helm_render(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            chart_directory = Path(temporary_directory) / "chart"
            shutil.copytree(CHART_PATH, chart_directory)
            (chart_directory / "manifests" / LINKS_DOCUMENT).unlink()

            result = subprocess.run(
                [
                    "helm",
                    "template",
                    "kubeflow-dashboard",
                    str(chart_directory),
                    "--namespace",
                    "kubeflow",
                ],
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing or empty", result.stderr)

    def test_packaged_chart_contains_every_generated_file(self):
        expected_files = {
            f"kubeflow-dashboard/manifests/{CRDS_PAYLOAD}",
            f"kubeflow-dashboard/manifests/{RESOURCES_PAYLOAD}",
            f"kubeflow-dashboard/manifests/{LINKS_DOCUMENT}",
            f"kubeflow-dashboard/manifests/{SETTINGS_DOCUMENT}",
            f"kubeflow-dashboard/manifests/{NAMESPACE_LABELS_DOCUMENT}",
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
            self.assertTrue(expected_files.issubset(packaged_files))


if __name__ == "__main__":
    unittest.main()
