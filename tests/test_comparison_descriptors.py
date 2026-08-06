#!/usr/bin/env python3

import tempfile
import unittest
from pathlib import Path

import run_helm_kustomize_comparison as comparison


class DescriptorTest(unittest.TestCase):
    """Guards over the descriptors this repository actually ships."""

    @classmethod
    def setUpClass(cls):
        cls.descriptors = comparison.discover()

    def test_every_chart_declares_how_it_is_compared(self):
        """Discovery skips a chart with no descriptor, so nothing else would.

        Without this, a contributor can add a chart, omit one file, and get a
        green build with no parity coverage at all.
        """
        for pattern in comparison.CHART_GLOBS:
            for chart in comparison.ROOT_DIRECTORY.glob(pattern):
                if not (chart / "Chart.yaml").is_file():
                    continue
                with self.subTest(
                    chart=str(chart.relative_to(comparison.ROOT_DIRECTORY))
                ):
                    self.assertTrue(
                        (chart / "ci" / "comparison.yaml").is_file(),
                        "every chart must declare ci/comparison.yaml so it is compared",
                    )

    def test_declared_paths_exist(self):
        """A typo would otherwise surface as an opaque kustomize build error."""
        for component, (chart, descriptor) in self.descriptors.items():
            for name, scenario in descriptor["scenarios"].items():
                with self.subTest(component=component, scenario=name):
                    for path in scenario["kustomize"]:
                        self.assertTrue(
                            (comparison.ROOT_DIRECTORY / path).is_dir(), path
                        )
                    if scenario.get("values"):
                        self.assertTrue((chart / scenario["values"]).is_file())


class MalformedDescriptorTest(unittest.TestCase):
    """A descriptor decides what is compared, so a broken one must not load."""

    def load(self, body):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "comparison.yaml"
            path.write_text("component: x\nreleaseName: x\nnamespace: n\n" + body)
            return comparison.load_descriptor(path)

    def test_a_repeated_scenario_name_is_rejected(self):
        """PyYAML keeps the last duplicate, silently dropping parity coverage."""
        with self.assertRaises(Exception) as error:
            self.load(
                "scenarios:\n  a:\n    kustomize: [x]\n  a:\n    kustomize: [y]\n"
            )
        self.assertIn("duplicate key", str(error.exception))

    def test_a_scenario_without_kustomize_targets_is_rejected(self):
        with self.assertRaises(ValueError):
            self.load("scenarios:\n  a:\n    values: v.yaml\n")

    def test_a_default_scenario_that_is_not_declared_is_rejected(self):
        """Katib's old default was 'base', a scenario Katib does not have, so
        comparing it without naming one could only ever fail."""
        with self.assertRaises(ValueError):
            self.load(
                "defaultScenario: base\n"
                "scenarios:\n  standalone:\n    kustomize: [x]\n"
                "  platform:\n    kustomize: [y]\n"
            )


if __name__ == "__main__":
    unittest.main()
