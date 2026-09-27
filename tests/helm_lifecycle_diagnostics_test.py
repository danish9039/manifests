#!/usr/bin/env python3
"""Exercise evidence preservation on failed lifecycle operations, without a cluster."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LifecycleDiagnosticsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.scripts = self.directory / "tests"
        self.scripts.mkdir()
        for name in (
            "knative_serving_helm_lifecycle_test.sh",
            "kserve_ui_helm_lifecycle_test.sh",
            "helm_lifecycle_diagnostics.sh",
        ):
            source = ROOT / "tests" / name
            if source.exists():
                shutil.copy(source, self.scripts / name)
        for name in (
            "knative_serving_helm_admission_test.sh",
            "knative_serving_helm_smoke_test.sh",
        ):
            self.executable(self.scripts / name, "#!/bin/sh\nexit 0\n")
        self.executable(
            self.directory / "helm",
            """#!/bin/sh
echo "helm $*" >> "$COMMAND_LOG"
case "$1" in
  status) echo '{"version":1}';;
  upgrade) exit 42;;
esac
""",
        )
        self.executable(
            self.directory / "kubectl",
            """#!/bin/sh
echo "kubectl $*" >> "$COMMAND_LOG"
case "$*" in
  *'get all'*) echo 'API query failed' >&2; exit 17;;
  *'get pods'*'-o name'*) echo pod/example;;
  *'logs '*) echo 'controller evidence';;
  *) echo '{"metadata":{"uid":"retained"},"items":[]}';;
esac
""",
        )
        self.evidence = self.directory / "logs"
        self.environment = os.environ | {
            "PATH": f"{self.directory}:{os.environ['PATH']}",
            "COMMAND_LOG": str(self.directory / "commands"),
            "EVIDENCE_DIRECTORY": str(self.evidence),
        }

    def executable(self, path, content):
        path.write_text(content)
        path.chmod(0o755)

    def run_script(self, name, *arguments):
        return subprocess.run(
            ["bash", str(self.scripts / name), *arguments],
            cwd=self.directory,
            env=self.environment,
            text=True,
            capture_output=True,
            timeout=15,
        )

    def test_knative_failure_keeps_fixtures_and_collects_before_mutation(self):
        result = self.run_script("knative_serving_helm_lifecycle_test.sh", "profile")
        self.assertEqual(result.returncode, 42, result.stderr)
        commands = (self.directory / "commands").read_text()
        self.assertNotIn(" delete ", commands)
        self.assertLess(commands.index("logs pod/"), commands.index("helm upgrade"))
        self.assertTrue((self.evidence / "failure").is_dir())

    def test_ui_failure_preserves_identity_snapshots_and_original_status(self):
        result = self.run_script("kserve_ui_helm_lifecycle_test.sh", "profile", "model")
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertTrue((self.evidence / "namespace-before.json").is_file())
        self.assertTrue((self.evidence / "failure").is_dir())
        commands = (self.directory / "commands").read_text()
        self.assertLess(commands.index("logs pod/"), commands.index("helm upgrade"))

    def test_failed_query_does_not_stop_remaining_diagnostics(self):
        result = self.run_script(
            "helm_lifecycle_diagnostics.sh", str(self.evidence), "kserve", "release"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "API query failed", (self.evidence / "kserve-resources.yaml").read_text()
        )
        self.assertIn(
            "controller evidence", (self.evidence / "kserve-example.log").read_text()
        )


if __name__ == "__main__":
    unittest.main()
