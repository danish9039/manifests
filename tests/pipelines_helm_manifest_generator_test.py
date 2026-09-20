#!/usr/bin/env python3

import importlib.util
import os
import shlex
import shutil
import subprocess
import tempfile
import unittest

from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
GENERATOR_SCRIPT = "scripts/generate-pipelines-helm-manifests.py"
GENERATOR_PATH = REPOSITORY_ROOT / GENERATOR_SCRIPT
OUTPUT_PATH = Path("applications/pipeline/helm/manifests")
PLATFORM_DATABASE_KUSTOMIZE_PATH = Path("applications/pipeline/overlays")
PLATFORM_KUBERNETES_NATIVE_KUSTOMIZE_PATH = Path(
    "applications/pipeline/upstream/env/cert-manager/"
    "platform-agnostic-multi-user-k8s-native"
)
PAYLOAD_FILE_NAMES = [
    "common-crds.yaml",
    "common-resources.yaml",
    "platform-database-crds.yaml",
    "platform-database-resources.yaml",
    "platform-kubernetes-native-crds.yaml",
    "platform-kubernetes-native-resources.yaml",
]

SHARED_KUSTOMIZE_INPUT = """\
apiVersion: v1
kind: Service
metadata:
  name: ml-pipeline
  namespace: kubeflow
  labels:
    app: ml-pipeline
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: examples.kubeflow.org
spec:
  group: kubeflow.org
  names:
    kind: Example
    plural: examples
  scope: Namespaced
  versions: []
"""

SCENARIO_KUSTOMIZE_INPUT = """\
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: pipeline-install-config
  namespace: kubeflow
data:
  scenario: {scenario}
"""


def load_generator_module():
    if not GENERATOR_PATH.is_file():
        raise AssertionError(f"Generator file does not exist: {GENERATOR_PATH}")

    module_specification = importlib.util.spec_from_file_location(
        "generate_pipelines_helm_manifests",
        GENERATOR_PATH,
    )
    if module_specification is None or module_specification.loader is None:
        raise AssertionError(f"Cannot load generator module: {GENERATOR_PATH}")

    generator_module = importlib.util.module_from_spec(module_specification)
    module_specification.loader.exec_module(generator_module)
    return generator_module


class ResourceIdentityTest(unittest.TestCase):
    def test_resource_identity_includes_namespace_and_rejects_missing_name(self):
        generator_module = load_generator_module()
        resource = {
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": {
                "name": "ml-pipeline",
                "namespace": "kubeflow",
            },
        }

        self.assertEqual(
            generator_module.resource_identity(resource),
            ("apps/v1", "Deployment", "kubeflow", "ml-pipeline"),
        )

        with self.assertRaisesRegex(ValueError, "metadata.name"):
            generator_module.resource_identity(
                {
                    "apiVersion": "apps/v1",
                    "kind": "Deployment",
                    "metadata": {"namespace": "kubeflow"},
                }
            )


class ResourceIndexTest(unittest.TestCase):
    def test_index_resources_rejects_duplicate_resource_identity(self):
        generator_module = load_generator_module()
        self.assertTrue(
            hasattr(generator_module, "index_resources"),
            "Generator must define index_resources",
        )
        duplicate_resource = {
            "apiVersion": "v1",
            "kind": "Service",
            "metadata": {
                "name": "ml-pipeline",
                "namespace": "kubeflow",
            },
        }

        with self.assertRaisesRegex(ValueError, "Duplicate resource identity"):
            generator_module.index_resources(
                [duplicate_resource, duplicate_resource],
                "platform-database",
            )


class ScenarioPartitionTest(unittest.TestCase):
    def test_partition_scenarios_deduplicates_identical_resources(self):
        generator_module = load_generator_module()
        self.assertTrue(
            hasattr(generator_module, "partition_scenarios"),
            "Generator must define partition_scenarios",
        )

        shared_service = {
            "apiVersion": "v1",
            "kind": "Service",
            "metadata": {"name": "ml-pipeline", "namespace": "kubeflow"},
            "spec": {"ports": [{"port": 8888}]},
        }
        database_deployment = {
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": {"name": "ml-pipeline", "namespace": "kubeflow"},
            "spec": {"replicas": 1},
        }
        kubernetes_native_deployment = {
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": {"name": "ml-pipeline", "namespace": "kubeflow"},
            "spec": {"replicas": 2},
        }
        database_crd = {
            "apiVersion": "apiextensions.k8s.io/v1",
            "kind": "CustomResourceDefinition",
            "metadata": {"name": "applications.app.k8s.io"},
            "spec": {},
        }
        kubernetes_native_crd = {
            "apiVersion": "apiextensions.k8s.io/v1",
            "kind": "CustomResourceDefinition",
            "metadata": {"name": "pipelines.pipelines.kubeflow.org"},
            "spec": {},
        }

        partitions = generator_module.partition_scenarios(
            [shared_service, database_deployment, database_crd],
            [
                shared_service,
                kubernetes_native_deployment,
                kubernetes_native_crd,
            ],
        )

        self.assertEqual(partitions["common_resources"], [shared_service])
        self.assertEqual(partitions["common_crds"], [])
        self.assertEqual(partitions["platform_database_crds"], [database_crd])
        self.assertEqual(
            partitions["platform_database_resources"],
            [database_deployment],
        )
        self.assertEqual(
            partitions["platform_kubernetes_native_crds"],
            [kubernetes_native_crd],
        )
        self.assertEqual(
            partitions["platform_kubernetes_native_resources"],
            [kubernetes_native_deployment],
        )


class HelmRenderingSafetyTest(unittest.TestCase):
    def test_payload_keeps_argo_expressions_verbatim(self):
        """Payloads are read with .Files.Get, so nothing may be escaped.

        Argo templates such as {{workflow.name}} have to survive byte for byte.
        Escaping them was only needed while payloads lived under templates/.
        """
        generator_module = load_generator_module()
        self.assertFalse(
            hasattr(generator_module, "escape_helm_delimiters"),
            "Payloads are no longer evaluated by Helm, so escaping must be gone",
        )
        resource = {
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {"name": "artifact-repositories"},
            "data": {
                "keyFormat": "private-artifacts/{{workflow.namespace}}/{{pod.name}}",
            },
        }

        payload = generator_module.render_partition_payload(
            [resource], "applications/pipeline/overlays"
        )

        self.assertIn("{{workflow.namespace}}", payload)
        self.assertNotIn('{{ "{{" }}', payload)

    def test_add_crd_retention_annotation_preserves_source_resource(self):
        generator_module = load_generator_module()
        self.assertTrue(
            hasattr(generator_module, "add_crd_retention_annotation"),
            "Generator must define add_crd_retention_annotation",
        )
        source_resource = {
            "apiVersion": "apiextensions.k8s.io/v1",
            "kind": "CustomResourceDefinition",
            "metadata": {
                "name": "applications.app.k8s.io",
                "annotations": {"example.com/source": "kustomize"},
            },
            "spec": {},
        }

        rendered_resource = generator_module.add_crd_retention_annotation(
            source_resource
        )

        self.assertNotIn(
            "helm.sh/resource-policy",
            source_resource["metadata"]["annotations"],
        )
        self.assertEqual(
            rendered_resource["metadata"]["annotations"],
            {
                "example.com/source": "kustomize",
                "helm.sh/resource-policy": "keep",
            },
        )

    def test_render_partition_payload_is_plain_yaml_with_a_header(self):
        """No {{- if }} wrapper: when a payload applies is the chart's decision."""
        generator_module = load_generator_module()
        crd_resource = {
            "apiVersion": "apiextensions.k8s.io/v1",
            "kind": "CustomResourceDefinition",
            "metadata": {"name": "applications.app.k8s.io"},
            "spec": {
                "description": "Literal {{workflow.name}} expression",
            },
        }

        payload = generator_module.render_partition_payload(
            [crd_resource],
            "applications/pipeline/overlays",
        )

        self.assertTrue(
            payload.startswith(
                "# Code generated by scripts/generate-pipelines-helm-manifests.py.\n"
            )
        )
        self.assertIn("helm.sh/resource-policy: keep", payload)
        self.assertIn("{{workflow.name}}", payload)
        self.assertIn(
            "# Source Kustomize path: applications/pipeline/overlays",
            payload,
        )
        self.assertNotIn("{{- if ", payload)
        self.assertNotIn("{{- end }}", payload)

    def test_write_generated_payloads_preserves_existing_directory_on_failure(self):
        generator_module = load_generator_module()
        self.assertTrue(
            hasattr(generator_module, "write_generated_payloads"),
            "Generator must define write_generated_payloads",
        )

        with tempfile.TemporaryDirectory() as temporary_directory_name:
            temporary_directory = Path(temporary_directory_name)
            output_directory = temporary_directory / "generated"
            output_directory.mkdir()
            existing_file = output_directory / "existing.yaml"
            existing_file.write_text("preserved\n")

            with self.assertRaises(TypeError):
                generator_module.write_generated_payloads(
                    {"new.yaml": object()},
                    output_directory,
                )

            self.assertEqual(existing_file.read_text(), "preserved\n")
            self.assertFalse((output_directory / "new.yaml").exists())


class GeneratedTemplateSetTest(unittest.TestCase):
    def test_build_generated_payloads_creates_common_and_scenario_payloads(self):
        generator_module = load_generator_module()
        self.assertTrue(
            hasattr(generator_module, "build_generated_payloads"),
            "Generator must define build_generated_payloads",
        )
        shared_crd = {
            "apiVersion": "apiextensions.k8s.io/v1",
            "kind": "CustomResourceDefinition",
            "metadata": {"name": "decoratorcontrollers.metacontroller.k8s.io"},
            "spec": {},
        }
        shared_service = {
            "apiVersion": "v1",
            "kind": "Service",
            "metadata": {"name": "ml-pipeline", "namespace": "kubeflow"},
            "spec": {},
        }
        database_application = {
            "apiVersion": "app.k8s.io/v1beta1",
            "kind": "Application",
            "metadata": {"name": "kubeflow", "namespace": "kubeflow"},
            "spec": {},
        }
        kubernetes_native_certificate = {
            "apiVersion": "cert-manager.io/v1",
            "kind": "Certificate",
            "metadata": {
                "name": "kfp-api-webhook-cert",
                "namespace": "kubeflow",
            },
            "spec": {},
        }

        generated_templates = generator_module.build_generated_payloads(
            [shared_crd, shared_service, database_application],
            [shared_crd, shared_service, kubernetes_native_certificate],
        )

        self.assertEqual(
            set(generated_templates),
            {
                "common-crds.yaml",
                "common-resources.yaml",
                "platform-database-crds.yaml",
                "platform-database-resources.yaml",
                "platform-kubernetes-native-crds.yaml",
                "platform-kubernetes-native-resources.yaml",
            },
        )
        # Payloads carry no conditions. A template under templates/ decides when
        # each one applies, so the generator does not encode chart behaviour.
        for payload in generated_templates.values():
            self.assertNotIn("{{- if ", payload)
            self.assertNotIn(".Values.", payload)
        self.assertIn(
            "kind: CustomResourceDefinition",
            generated_templates["common-crds.yaml"],
        )
        self.assertIn(
            "kind: Service",
            generated_templates["common-resources.yaml"],
        )


def write_fixture_repository(root):
    """Two tiny local Kustomize bases at the paths the generator renders."""
    for kustomize_path, scenario in (
        (PLATFORM_DATABASE_KUSTOMIZE_PATH, "platform-database"),
        (PLATFORM_KUBERNETES_NATIVE_KUSTOMIZE_PATH, "platform-k8s-native"),
    ):
        kustomize_directory = root / kustomize_path
        kustomize_directory.mkdir(parents=True)
        (kustomize_directory / "resources.yaml").write_text(
            SHARED_KUSTOMIZE_INPUT + SCENARIO_KUSTOMIZE_INPUT.format(scenario=scenario)
        )
        (kustomize_directory / "kustomization.yaml").write_text(
            "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n"
            "resources:\n- resources.yaml\n"
        )
    return root / PLATFORM_DATABASE_KUSTOMIZE_PATH / "resources.yaml"


def snapshot(directory):
    """Everything --check could disturb: entries, inodes, times and bytes."""
    entries = {}
    for path in [directory, *directory.rglob("*")]:
        status = path.stat()
        entries[str(path)] = (
            status.st_ino,
            status.st_mtime_ns,
            None if path.is_dir() else path.read_bytes(),
        )
    siblings = sorted(str(path) for path in directory.parent.iterdir())
    return entries, siblings


def run_generator(root, *arguments, working_directory=None):
    return subprocess.run(
        ["python3", str(GENERATOR_PATH), "--repository-root", str(root), *arguments],
        cwd=working_directory or root,
        capture_output=True,
        text=True,
    )


def advertised_repair(stderr):
    return next(
        line.split(": ", 1)[1]
        for line in stderr.splitlines()
        if line.startswith("Regenerate with: ")
    )


class FreshnessCheckTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve() / "repository"
        self.input_path = write_fixture_repository(self.root)
        self.output_directory = self.root / OUTPUT_PATH
        generated = run_generator(self.root)
        self.assertEqual(generated.returncode, 0, generated.stderr)

    def assert_differences(self, result, expected_lines):
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(
            [line for line in result.stderr.splitlines() if line.startswith("  ")],
            expected_lines,
        )

    def test_freshly_generated_payloads_are_fresh(self):
        result = run_generator(self.root, "--check")

        self.assertEqual((result.returncode, result.stderr), (0, ""))
        self.assertEqual(
            result.stdout,
            f"Kubeflow Pipelines payloads in {OUTPUT_PATH} are fresh.\n",
        )
        self.assertEqual(
            sorted(path.name for path in self.output_directory.iterdir()),
            PAYLOAD_FILE_NAMES,
        )

    def test_an_edited_input_is_detected(self):
        self.input_path.write_text(
            self.input_path.read_text().replace("app: ml-pipeline", "app: renamed")
        )

        result = run_generator(self.root, "--check")

        # The Service no longer equals its counterpart of the other scenario,
        # so it leaves the common payload and enters both scenario payloads.
        self.assert_differences(
            result,
            [
                "  stale    common-resources.yaml",
                "  stale    platform-database-resources.yaml",
                "  stale    platform-kubernetes-native-resources.yaml",
            ],
        )
        self.assertIn(
            f"Regenerate with: python3 {GENERATOR_SCRIPT} "
            f"--repository-root {shlex.quote(str(self.root))}\n",
            result.stderr,
        )
        self.assertNotIn("synchronize", result.stderr)

    def test_a_line_ending_change_is_stale(self):
        """read_text would normalise CRLF away; the bytes Helm packages differ."""
        path = self.output_directory / "common-resources.yaml"
        path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n"))

        self.assert_differences(
            run_generator(self.root, "--check"),
            ["  stale    common-resources.yaml"],
        )

    def test_missing_and_extra_files_are_reported(self):
        (self.output_directory / "common-crds.yaml").unlink()
        (self.output_directory / "stray.yaml").write_text("kind: Stray\n")

        self.assert_differences(
            run_generator(self.root, "--check"),
            ["  missing  common-crds.yaml", "  extra    stray.yaml"],
        )

    def test_a_missing_output_directory_reports_every_file_missing(self):
        shutil.rmtree(self.output_directory)

        self.assert_differences(
            run_generator(self.root, "--check"),
            [f"  missing  {file_name}" for file_name in PAYLOAD_FILE_NAMES],
        )
        self.assertFalse(self.output_directory.exists())

    def test_a_render_failure_is_an_error_status_in_both_modes(self):
        (self.input_path.parent / "kustomization.yaml").write_text("resources: [\n")
        before = snapshot(self.output_directory)

        for mode in ([], ["--check"]):
            with self.subTest(mode=mode):
                result = run_generator(self.root, *mode)
                self.assertEqual((result.returncode, result.stdout), (1, ""))
                self.assertIn("ERROR: Kustomize rendering failed", result.stderr)
                self.assertEqual(snapshot(self.output_directory), before)

    def test_check_never_writes(self):
        """On a fresh and a stale tree alike: no file, inode, modification
        time or staging directory changes."""
        fresh = snapshot(self.output_directory)
        self.assertEqual(run_generator(self.root, "--check").returncode, 0)
        self.assertEqual(snapshot(self.output_directory), fresh)

        self.input_path.write_text(
            self.input_path.read_text().replace("app: ml-pipeline", "app: renamed")
        )
        (self.output_directory / "stray.yaml").write_text("kind: Stray\n")
        stale = snapshot(self.output_directory)
        self.assertEqual(run_generator(self.root, "--check").returncode, 1)
        self.assertEqual(snapshot(self.output_directory), stale)

    def test_the_requested_output_directory_is_the_one_checked(self):
        """The default directory is fresh; only the requested one is judged."""
        requested_directory = self.root.parent / "requested"

        result = run_generator(
            self.root, "--check", "--output-directory", str(requested_directory)
        )

        self.assert_differences(
            result,
            [f"  missing  {file_name}" for file_name in PAYLOAD_FILE_NAMES],
        )
        self.assertIn(f"payloads in {requested_directory} are not", result.stderr)
        self.assertFalse(requested_directory.exists())

    def test_the_advertised_repair_runs_with_paths_that_contain_spaces(self):
        """The printed command is executed as printed, from the repository
        root, although the check was typed elsewhere with relative paths, so
        resolution and quoting are part of the contract."""
        kustomize_binary = shutil.which("kustomize")
        self.assertIsNotNone(kustomize_binary, "kustomize must be on PATH")
        parent = self.root.parent
        root = parent / "repository with spaces"
        write_fixture_repository(root)
        output_directory = parent / "output with spaces" / "manifests"
        binary_directory = parent / "binaries with spaces"
        binary_directory.mkdir()
        renamed_kustomize_binary = binary_directory / "renamed-kustomize"
        os.symlink(kustomize_binary, renamed_kustomize_binary)
        options = [
            "--output-directory",
            "output with spaces/manifests",
            "--kustomize-binary",
            str(renamed_kustomize_binary),
        ]

        checked = subprocess.run(
            [
                "python3",
                str(GENERATOR_PATH),
                "--check",
                "--repository-root",
                "repository with spaces",
                *options,
            ],
            cwd=parent,
            capture_output=True,
            text=True,
        )

        self.assertEqual(checked.returncode, 1, checked.stderr)
        advertised = advertised_repair(checked.stderr)
        self.assertEqual(
            shlex.split(advertised),
            [
                "python3",
                GENERATOR_SCRIPT,
                "--repository-root",
                str(root),
                "--output-directory",
                str(output_directory),
                "--kustomize-binary",
                str(renamed_kustomize_binary),
            ],
        )

        # The fixture repository has no copy of the generator, so the relative
        # script path of the advertised command is made to resolve there.
        (root / "scripts").mkdir()
        os.symlink(GENERATOR_PATH, root / GENERATOR_SCRIPT)
        repaired = subprocess.run(
            shlex.split(advertised), cwd=root, capture_output=True, text=True
        )

        self.assertEqual(repaired.returncode, 0, repaired.stderr)
        self.assertEqual(
            sorted(path.name for path in output_directory.iterdir()),
            PAYLOAD_FILE_NAMES,
        )
        self.assertFalse((root / OUTPUT_PATH).exists())
        rechecked = subprocess.run(
            [*shlex.split(advertised), "--check"],
            cwd=root,
            capture_output=True,
            text=True,
        )
        self.assertEqual((rechecked.returncode, rechecked.stderr), (0, ""))
        self.assertIn("are fresh", rechecked.stdout)

    def test_the_default_options_are_not_carried_by_the_repair(self):
        generator_module = load_generator_module()

        self.assertEqual(
            generator_module.repair_command(generator_module.parse_arguments([])),
            f"python3 {GENERATOR_SCRIPT}",
        )


if __name__ == "__main__":
    unittest.main()
