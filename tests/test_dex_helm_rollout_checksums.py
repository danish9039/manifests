#!/usr/bin/env python3

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT_DIRECTORY = Path(__file__).resolve().parents[1]
CHART_DIRECTORY = ROOT_DIRECTORY / "common" / "dex" / "helm"
HELM_BINARY = os.environ.get("HELM_BINARY", "helm")
CHECKSUM_KEYS = {
    "checksum/config",
    "checksum/oidc-client",
    "checksum/passwords",
}


class DexRolloutChecksumTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.helm_plugins = tempfile.TemporaryDirectory()

    @classmethod
    def tearDownClass(cls):
        cls.helm_plugins.cleanup()

    def render_checksums(self, *values):
        command = [
            HELM_BINARY,
            "template",
            "dex",
            str(CHART_DIRECTORY),
            "--namespace",
            "auth",
        ]
        for value in values:
            command.extend(["--set-string", value])

        environment = os.environ.copy()
        environment["HELM_PLUGINS"] = self.helm_plugins.name
        result = subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
            env=environment,
        )
        manifests = [
            manifest for manifest in yaml.safe_load_all(result.stdout) if manifest
        ]
        deployment = next(
            manifest
            for manifest in manifests
            if manifest.get("kind") == "Deployment"
            and manifest.get("metadata", {}).get("name") == "dex"
        )
        return deployment["spec"]["template"]["metadata"].get("annotations", {})

    def test_checksums_are_stable_and_change_only_for_their_startup_input(self):
        baseline = self.render_checksums()

        self.assertEqual(set(baseline), CHECKSUM_KEYS)
        for checksum in baseline.values():
            self.assertRegex(checksum, re.compile(r"^[0-9a-f]{64}$"))

        self.assertEqual(self.render_checksums(), baseline)
        self.assertEqual(
            self.changed_keys(baseline, self.render_checksums("config.logLevel=debug")),
            {"checksum/config"},
        )
        self.assertEqual(
            self.changed_keys(
                baseline,
                self.render_checksums("oidcClient.secret=changed-oidc-secret"),
            ),
            {"checksum/oidc-client"},
        )
        self.assertEqual(
            self.changed_keys(
                baseline,
                self.render_checksums("staticPassword.hash=changed-password-hash"),
            ),
            {"checksum/passwords"},
        )
        self.assertEqual(self.render_checksums("dex.replicas=3"), baseline)

    @staticmethod
    def changed_keys(before, after):
        return {key for key in CHECKSUM_KEYS if before[key] != after[key]}


if __name__ == "__main__":
    unittest.main()
