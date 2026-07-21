import importlib.util
import unittest
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
SELECTOR_PATH = REPOSITORY_ROOT / "tests/resynchronize-upstream-changes.py"
MODULE_SPEC = importlib.util.spec_from_file_location(
    "resynchronize_upstream_changes", SELECTOR_PATH
)
RESYNCHRONIZE_UPSTREAM_CHANGES = importlib.util.module_from_spec(MODULE_SPEC)
assert MODULE_SPEC.loader is not None
MODULE_SPEC.loader.exec_module(RESYNCHRONIZE_UPSTREAM_CHANGES)


class ResynchronizeUpstreamChangesTest(unittest.TestCase):
    def test_notebooks_paths_select_only_notebooks_synchronization(self):
        expected_scripts = {Path("scripts/synchronize-notebooks-v1-manifests.sh")}
        positive_paths = [
            Path(
                "applications/notebooks-v1/upstream/jupyter-web-app/base/kustomization.yaml"
            ),
            Path("applications/notebooks-v1/helm/Chart.yaml"),
            Path("applications/notebooks-v1/helm/kustomize/kustomization.yaml"),
            Path("applications/notebooks-v1/helm/templates/platform.yaml"),
        ]

        for changed_path in positive_paths:
            with self.subTest(changed_path=changed_path):
                self.assertEqual(
                    RESYNCHRONIZE_UPSTREAM_CHANGES.find_upstream_scripts(
                        [changed_path]
                    ),
                    expected_scripts,
                )

    def test_unrelated_notebooks_paths_select_no_synchronization(self):
        negative_paths = [
            Path("applications/notebooks-v1/helm/values.yaml"),
            Path("applications/notebooks-v1/helm/ci/values-platform.yaml"),
            Path("applications/notebooks-v1/helm/README.md"),
            Path("applications/notebooks-v1/helm/templates/validate.yaml"),
            Path("applications/notebooks-v1/helmish/Chart.yaml"),
            Path("scripts/library.sh"),
            Path("scripts/unrelated.py"),
        ]

        for changed_path in negative_paths:
            with self.subTest(changed_path=changed_path):
                self.assertEqual(
                    RESYNCHRONIZE_UPSTREAM_CHANGES.find_upstream_scripts(
                        [changed_path]
                    ),
                    set(),
                )


if __name__ == "__main__":
    unittest.main()
