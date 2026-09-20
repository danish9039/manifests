#!/usr/bin/env python3

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT_DIRECTORY = Path(__file__).resolve().parents[1]
CHART_DIRECTORY = ROOT_DIRECTORY / "applications" / "spark" / "spark-operator" / "helm"
SYNCHRONIZATION_SCRIPT = (
    ROOT_DIRECTORY / "scripts" / "synchronize-spark-operator-manifests.sh"
)
COMPARISON_WORKFLOW = (
    ROOT_DIRECTORY / ".github" / "workflows" / "helm-kustomize-comparison.yml"
)
HELM_BINARY = os.environ.get("HELM_BINARY", "helm")
CHART_REPOSITORY = "https://kubeflow.github.io/spark-operator"

# The upstream chart derives resource names and spec.selector.matchLabels from
# .Release.Name, and the Kustomize baseline was rendered with this one.
RELEASE_NAME = "spark-operator"
OWNED_NAMESPACE = "kubeflow"
SIDECAR_INJECTION_LABEL = "sidecar.istio.io/inject"
AGGREGATED_ROLES = {
    "kubeflow-spark-admin",
    "kubeflow-spark-edit",
    "kubeflow-spark-view",
}


class SparkOperatorHelmChartTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Helm reads and writes repository configuration, the repository cache
        # and plugins under these three homes. Isolating all of them keeps the
        # developer's Helm state out of the test and the test out of it.
        cls.work_directory = tempfile.TemporaryDirectory()
        work_directory = Path(cls.work_directory.name)
        cls.environment = os.environ.copy()
        for variable in ("HELM_CACHE_HOME", "HELM_CONFIG_HOME", "HELM_DATA_HOME"):
            cls.environment[variable] = str(work_directory / variable.lower())
        cls.environment["HELM_PLUGINS"] = str(work_directory / "helm_plugins")

        # The dependency is built in a copy, so no archive is left in the
        # source tree.
        cls.chart_directory = work_directory / "chart"
        cls.source_tree_before = cls.source_tree()
        shutil.copytree(
            CHART_DIRECTORY, cls.chart_directory, ignore=shutil.ignore_patterns("*.tgz")
        )
        for command in (
            [HELM_BINARY, "repo", "add", "spark-operator", CHART_REPOSITORY],
            [HELM_BINARY, "dependency", "build", str(cls.chart_directory)],
        ):
            dependencies = subprocess.run(
                command, capture_output=True, text=True, env=cls.environment
            )
            if dependencies.returncode != 0:
                cls.work_directory.cleanup()
                message = f"chart dependency is unavailable: {dependencies.stderr}"
                # Continuous integration must never report a skipped suite as
                # a pass; a developer without network access may skip it.
                if os.environ.get("GITHUB_ACTIONS") == "true":
                    raise AssertionError(message)
                raise unittest.SkipTest(message)

        cls.manifests = cls.render()

    @staticmethod
    def source_tree():
        return sorted(
            str(path.relative_to(CHART_DIRECTORY))
            for path in CHART_DIRECTORY.rglob("*")
        )

    @classmethod
    def tearDownClass(cls):
        cls.work_directory.cleanup()

    @classmethod
    def template(cls, *values, release_name=RELEASE_NAME, namespace=OWNED_NAMESPACE):
        command = [
            HELM_BINARY,
            "template",
            release_name,
            str(cls.chart_directory),
            "--namespace",
            namespace,
            "--include-crds",
        ]
        for value in values:
            command.extend(["--set", value])
        return subprocess.run(
            command, capture_output=True, text=True, env=cls.environment
        )

    @classmethod
    def render(cls, *values):
        result = cls.template(*values)
        if result.returncode != 0:
            raise AssertionError(f"helm template failed: {result.stderr}")
        return [manifest for manifest in yaml.safe_load_all(result.stdout) if manifest]

    def find_manifest(self, manifests, kind, name):
        for manifest in manifests:
            if (
                manifest.get("kind") == kind
                and manifest.get("metadata", {}).get("name") == name
            ):
                return manifest
        raise AssertionError(f"{kind}/{name} was not rendered")

    def test_helm_homes_are_isolated_from_the_developer(self):
        for variable in ("HELM_CACHE_HOME", "HELM_CONFIG_HOME", "HELM_DATA_HOME"):
            with self.subTest(variable=variable):
                self.assertTrue(
                    self.environment[variable].startswith(self.work_directory.name)
                )
        # Building the dependency left nothing behind in the source tree.
        self.assertEqual(self.source_tree(), self.source_tree_before)

    def test_chart_refuses_a_foreign_namespace(self):
        result = self.template(namespace="not-kubeflow")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be installed into the kubeflow namespace", result.stderr)

    def test_chart_refuses_a_foreign_release_name(self):
        """Upstream derives names and selector labels from the release name.

        helm lint exits 0 even when a fail guard fires, so only a render
        proves the guard.
        """
        result = self.template(release_name="spark")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "must be installed with the release name spark-operator", result.stderr
        )

    def test_external_operator_mode_renders_only_the_aggregated_roles(self):
        manifests = self.render("spark-operator.enabled=false")

        self.assertEqual(
            sorted(
                (manifest["kind"], manifest["metadata"]["name"])
                for manifest in manifests
            ),
            sorted(("ClusterRole", name) for name in AGGREGATED_ROLES),
        )

    def test_sidecar_injection_is_disabled_on_the_pod_template_only(self):
        """The Kustomize patches target spec.template.metadata.labels.

        Upstream places controller.labels and webhook.labels in the pod
        template. If a release ever moved them to the Deployment, the pods would
        silently rejoin the mesh while the rendered manifest still looked
        configured.
        """
        for name in ("spark-operator-controller", "spark-operator-webhook"):
            with self.subTest(deployment=name):
                deployment = self.find_manifest(self.manifests, "Deployment", name)

                pod_labels = deployment["spec"]["template"]["metadata"]["labels"]
                self.assertEqual(pod_labels.get(SIDECAR_INJECTION_LABEL), "false")

                deployment_labels = deployment["metadata"].get("labels", {})
                self.assertNotIn(SIDECAR_INJECTION_LABEL, deployment_labels)

    def test_job_namespaces_selects_every_namespace(self):
        """[""] renders --namespaces="", an empty list renders no argument.

        The synchronization script passes --set "spark.jobNamespaces={}", which
        Helm parses as a list holding the empty string, so the baseline carries
        the argument.
        """
        for name in ("spark-operator-controller", "spark-operator-webhook"):
            with self.subTest(deployment=name):
                deployment = self.find_manifest(self.manifests, "Deployment", name)
                arguments = deployment["spec"]["template"]["spec"]["containers"][0][
                    "args"
                ]
                self.assertIn('--namespaces=""', arguments)

    def test_aggregated_roles_can_be_disabled(self):
        rendered = {
            manifest["metadata"]["name"]
            for manifest in self.manifests
            if manifest.get("kind") == "ClusterRole"
        }
        self.assertTrue(AGGREGATED_ROLES.issubset(rendered))

        without_roles = self.render("kubeflow.aggregatedRoles.enabled=false")
        remaining = {
            manifest["metadata"]["name"]
            for manifest in without_roles
            if manifest.get("kind") == "ClusterRole"
        }

        self.assertEqual(remaining & AGGREGATED_ROLES, set())
        self.assertEqual(
            len(self.manifests) - len(without_roles), len(AGGREGATED_ROLES)
        )


class SparkOperatorSynchronizationTest(unittest.TestCase):
    """Checks that read files only, so they run without the chart repository."""

    def test_dependency_version_matches_the_synchronized_upstream_commit(self):
        """The one maintenance hazard a wrapper introduces, made into a test."""
        script = SYNCHRONIZATION_SCRIPT.read_text()
        commit = re.search(r'^COMMIT="v?([^"]+)"', script, re.MULTILINE)
        self.assertIsNotNone(commit, "COMMIT is not declared in the script")

        chart = yaml.safe_load((CHART_DIRECTORY / "Chart.yaml").read_text())
        dependency = next(
            entry
            for entry in chart["dependencies"]
            if entry["name"] == "spark-operator"
        )

        self.assertEqual(dependency["version"], commit.group(1))
        self.assertEqual(str(chart["appVersion"]), commit.group(1))

    def test_dependency_version_is_pinned_exactly(self):
        """A range would let two installations render differently."""
        chart = yaml.safe_load((CHART_DIRECTORY / "Chart.yaml").read_text())
        dependency = next(
            entry
            for entry in chart["dependencies"]
            if entry["name"] == "spark-operator"
        )

        self.assertRegex(dependency["version"], r"^\d+\.\d+\.\d+")

    def test_synchronization_requires_the_helm_version_the_workflow_pins(self):
        """The baseline is Helm output, so both must render with one version."""
        script = SYNCHRONIZATION_SCRIPT.read_text()
        required = re.search(r'^HELM_VERSION="([^"]+)"', script, re.MULTILINE)
        self.assertIsNotNone(required, "HELM_VERSION is not declared in the script")
        self.assertIn('require_helm_version "$HELM_VERSION"', script)

        workflow = yaml.safe_load(COMPARISON_WORKFLOW.read_text())
        pins = {
            step["with"]["version"]
            for job in workflow["jobs"].values()
            for step in job.get("steps", [])
            if "azure/setup-helm" in step.get("uses", "")
        }
        self.assertEqual(pins, {required.group(1)})

    def test_the_helm_version_guard_runs_before_anything_is_changed(self):
        lines = SYNCHRONIZATION_SCRIPT.read_text().splitlines()
        guard = lines.index('require_helm_version "$HELM_VERSION"')
        for mutation in ("create_branch ", "clone_and_checkout ", "helm template "):
            first = next(
                index for index, line in enumerate(lines) if line.startswith(mutation)
            )
            self.assertLess(guard, first, mutation)

    def run_library(self, command, helm_version):
        """Run a scripts/library.sh function against a stand-in helm."""
        with tempfile.TemporaryDirectory() as directory:
            helm = Path(directory) / "helm"
            helm.write_text(f"#!/usr/bin/env bash\necho '{helm_version}'\n")
            helm.chmod(0o755)
            environment = dict(
                os.environ, PATH=f"{directory}{os.pathsep}{os.environ['PATH']}"
            )
            return subprocess.run(
                [
                    "bash",
                    "-c",
                    f'source "{ROOT_DIRECTORY}/scripts/library.sh"; {command}',
                ],
                capture_output=True,
                text=True,
                env=environment,
            )

    def test_the_helm_version_guard_is_exact_and_accepts_build_metadata(self):
        for found, accepted in (
            ("v4.2.2", True),
            ("v4.2.2+g1a2b3c4", True),
            ("v4.2.3", False),
            ("v4.3.0", False),
            ("v4.2.20", False),
            ("v3.18.4", False),
        ):
            with self.subTest(found=found):
                result = self.run_library("require_helm_version v4.2.2", found)
                self.assertEqual(result.returncode == 0, accepted, result.stderr)
                if not accepted:
                    self.assertIn("Helm v4.2.2 required", result.stderr)

    def test_one_version_bump_changes_every_version_string(self):
        """Run the script's own update function against a copy of the chart."""
        script = SYNCHRONIZATION_SCRIPT.read_text()
        function = re.search(
            r"^update_spark_operator_helm_chart\(\) \{\n.*?^\}\n",
            script,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(function)
        current = re.search(r'^COMMIT="v([^"]+)"', script, re.MULTILINE).group(1)

        with tempfile.TemporaryDirectory() as directory:
            chart = Path(directory) / "chart"
            shutil.copytree(CHART_DIRECTORY, chart)
            before = yaml.safe_load((chart / "Chart.yaml").read_text())
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    f'source "{ROOT_DIRECTORY}/scripts/library.sh"\n'
                    f"{function.group(0)}\n"
                    "update_spark_operator_helm_chart",
                ],
                capture_output=True,
                text=True,
                env=dict(os.environ, COMMIT="v97.98.99", CHART_DIRECTORY=str(chart)),
            )
            self.assertEqual(result.returncode, 0, result.stderr)

            after = yaml.safe_load((chart / "Chart.yaml").read_text())
            readme = (chart / "README.md").read_text()
            chart_text = (chart / "Chart.yaml").read_text()

        self.assertEqual(after["appVersion"], "97.98.99")
        self.assertEqual(after["dependencies"][0]["version"], "97.98.99")
        # The anchored expression leaves the chart's own version alone.
        self.assertEqual(after["version"], before["version"])
        self.assertNotIn(current, chart_text)
        self.assertNotIn(current, readme)
        self.assertIn("upstream Spark Operator `v97.98.99`", readme)
        self.assertIn("--version 97.98.99", readme)

    def test_readme_names_commands_and_files_that_exist(self):
        readme = (CHART_DIRECTORY / "README.md").read_text()

        for path in re.findall(r"python3 (tests/\S+\.py)", readme):
            with self.subTest(path=path):
                self.assertTrue((ROOT_DIRECTORY / path).is_file())
        # A GitHub tree URL is an HTML page, not a manifest kubectl can apply.
        self.assertNotIn("/tree/", readme)
        self.assertIn("helm show crds spark-operator", readme)
        self.assertIn(f"--repo {CHART_REPOSITORY}", readme)

    def test_chart_carries_no_crds_directory(self):
        """The dependency owns the definitions; a second copy would collide.

        Resources installed from a subchart crds directory carry no Helm
        ownership metadata, so declaring the same ones here would fail the
        ownership check on install.
        """
        self.assertFalse((CHART_DIRECTORY / "crds").exists())


if __name__ == "__main__":
    unittest.main()
