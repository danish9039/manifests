#!/usr/bin/env python3
"""Guard the changed-file to synchronization-script routing.

Deleting a route silently makes the idempotence job run no script for that
path, so the component is never regenerated and drift is never detected. One
table-driven test over the routes keeps that failure visible.
"""

import importlib.util
import unittest
from pathlib import Path

SELECTOR_PATH = (
    Path(__file__).resolve().parents[1] / "tests/resynchronize-upstream-changes.py"
)
_SPEC = importlib.util.spec_from_file_location(
    "resynchronize_upstream_changes", SELECTOR_PATH
)
selector = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(selector)

DASHBOARD_SCRIPT = Path("scripts/synchronize-dashboard-manifests.sh")

ROUTES = [
    "applications/dashboard/upstream/centraldashboard/base/kustomization.yaml",
    "applications/dashboard/overlays/istio/kustomization.yaml",
    "applications/dashboard/helm/Chart.yaml",
    "applications/dashboard/helm/kustomize/kustomization.yaml",
    "applications/dashboard/helm/manifests/platform-crds.yaml",
    "scripts/generate-dashboard-helm-manifests.py",
]


class ResynchronizeUpstreamChangesTest(unittest.TestCase):
    def test_every_dashboard_route_selects_the_dashboard_script(self):
        for route in ROUTES:
            with self.subTest(route=route):
                self.assertEqual(
                    selector.find_upstream_scripts([Path(route)]),
                    {DASHBOARD_SCRIPT},
                )

    def test_unrelated_path_selects_nothing(self):
        self.assertEqual(selector.find_upstream_scripts([Path("README.md")]), set())


if __name__ == "__main__":
    unittest.main()
