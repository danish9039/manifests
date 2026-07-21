import importlib.util
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
SELECTOR_PATH = REPOSITORY_ROOT / "tests/resynchronize-upstream-changes.py"

spec = importlib.util.spec_from_file_location("resynchronize_upstream_changes", SELECTOR_PATH)
selector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selector)


EXPECTED_SCRIPTS = {Path("scripts/synchronize-dashboard-manifests.sh")}


class ResynchronizeUpstreamChangesTest(unittest.TestCase):
    def test_dashboard_changes_select_dashboard_synchronization_script(self):
        positive_paths = {
            Path("applications/dashboard/upstream/base/kustomization.yaml"),
            Path("applications/dashboard/helm/Chart.yaml"),
            Path("applications/dashboard/helm/kustomize/base/kustomization.yaml"),
            Path("applications/dashboard/helm/manifests/central-dashboard-resources.yaml"),
            Path("scripts/generate-dashboard-helm-manifests.py"),
        }

        for path in positive_paths:
            with self.subTest(path=path):
                self.assertEqual(selector.find_upstream_scripts([path]), EXPECTED_SCRIPTS)

    def test_unrelated_dashboard_changes_select_no_synchronization_script(self):
        negative_paths = {
            Path("applications/dashboard/helm/values.yaml"),
            Path("applications/dashboard/helm/ci/values-platform.yaml"),
            Path("applications/dashboard/helm/README.md"),
            Path("applications/dashboard/helm/templates/generated-manifests.yaml"),
            Path("applications/dashboard/helmish/Chart.yaml"),
            Path("scripts/unrelated.py"),
        }

        for path in negative_paths:
            with self.subTest(path=path):
                self.assertEqual(selector.find_upstream_scripts([path]), set())
