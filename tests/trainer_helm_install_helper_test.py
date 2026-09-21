#!/usr/bin/env python3
"""The ordered installer must stop before later releases on readiness failure."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class TrainerInstallerTest(unittest.TestCase):
    def run_installer(self, failure=""):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            log = directory / "commands"
            stub = """#!/usr/bin/env python3
import os, pathlib, sys
command = pathlib.Path(sys.argv[0]).name + " " + " ".join(sys.argv[1:])
with open(os.environ["COMMAND_LOG"], "a") as log: log.write(command + "\\n")
if sys.argv[1:2] == ["version"]: print("v4.2.2")
if os.environ.get("FAIL_COMMAND") and os.environ["FAIL_COMMAND"] in command: sys.exit(1)
"""
            for name in ("helm", "kubectl"):
                executable = directory / name
                executable.write_text(stub)
                executable.chmod(0o755)
            environment = os.environ | {
                "PATH": f"{directory}:{os.environ['PATH']}",
                "COMMAND_LOG": str(log),
                "FAIL_COMMAND": failure,
            }
            result = subprocess.run(
                ["bash", str(ROOT / "tests/trainer_helm_install.sh")],
                env=environment,
                text=True,
                capture_output=True,
            )
            return result, log.read_text().splitlines()

    def test_definitions_then_controller_then_catalog_after_readiness(self):
        result, commands = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        installs = [
            command for command in commands if command.startswith("helm install")
        ]
        self.assertEqual(
            [command.split()[2] for command in installs],
            ["trainer-apis", "trainer", "trainer-runtimes"],
        )
        controller = commands.index(installs[1])
        catalog = commands.index(installs[2])
        established = [
            i
            for i, command in enumerate(commands)
            if "--for=condition=Established" in command
        ]
        self.assertEqual(len(established), 4)
        self.assertLess(max(established), controller)
        readiness = [
            i
            for i, command in enumerate(commands)
            if "caBundle" in command or "endpoints/" in command
        ]
        self.assertEqual(len(readiness), 6)
        self.assertTrue(all(controller < i < catalog for i in readiness))

    def test_failed_definition_establishment_prevents_controller_and_catalog(self):
        result, commands = self.run_installer("--for=condition=Established")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(
            any(command.startswith("helm install trainer ") for command in commands)
        )
        self.assertFalse(
            any(
                command.startswith("helm install trainer-runtimes ")
                for command in commands
            )
        )

    def test_failed_webhook_readiness_prevents_catalog(self):
        result, commands = self.run_installer("caBundle")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(
            any(
                command.startswith("helm install trainer-runtimes ")
                for command in commands
            )
        )


if __name__ == "__main__":
    unittest.main()
