import importlib.util
import unittest
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
SELECTOR_PATH = REPOSITORY_ROOT / "tests/resynchronize-upstream-changes.py"

spec = importlib.util.spec_from_file_location(
    "resynchronize_upstream_changes", SELECTOR_PATH
)
selector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selector)


EXPECTED_SCRIPTS = {Path("scripts/synchronize-dashboard-manifests.sh")}


class ResynchronizeUpstreamChangesTest(unittest.TestCase):
    def test_dashboard_overlay_selects_dashboard_synchronization_script(self):
        path = Path("applications/dashboard/overlays/istio/kustomization.yaml")

        self.assertEqual(selector.find_upstream_scripts([path]), EXPECTED_SCRIPTS)
