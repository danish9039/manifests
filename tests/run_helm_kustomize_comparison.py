#!/usr/bin/env python3
"""Compare a chart's rendered output against its Kustomize baseline.

Components are discovered, not registered. Every chart declares how it is
compared in its own `ci/comparison.yaml`, so adding a component touches only
that component's directory and never a shared list.
"""

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

ROOT_DIRECTORY = Path(__file__).resolve().parents[1]
COMPARATOR = Path(__file__).with_name("helm_kustomize_compare.py")
CHART_GLOBS = (
    "common/*/helm",
    "applications/*/helm",
    "applications/*/*/helm",
    "experimental/helm/charts/*",
)
DOCUMENT_SEPARATOR = "\n---\n"


class _StrictLoader(yaml.SafeLoader):
    """Reject duplicate keys, which PyYAML otherwise resolves to the last one.

    A repeated scenario name would silently discard every earlier definition and
    quietly reduce parity coverage. scripts/helm_manifest_generator.py refuses
    them for the same reason.
    """


def _no_duplicate_keys(loader, node, deep=False):
    seen = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            raise yaml.constructor.ConstructorError(
                None, None, f"duplicate key {key!r}", key_node.start_mark
            )
        seen.add(key)
    return yaml.SafeLoader.construct_mapping(loader, node, deep)


_StrictLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_duplicate_keys
)


def load_descriptor(path):
    """Read one descriptor, rejecting the mistakes that used to be possible."""
    descriptor = yaml.load(path.read_text(), Loader=_StrictLoader)
    for field in ("component", "releaseName", "namespace", "scenarios"):
        if not descriptor.get(field):
            raise ValueError(f"{path}: missing {field!r}")

    scenarios = descriptor["scenarios"]
    if not isinstance(scenarios, dict):
        raise ValueError(f"{path}: 'scenarios' must be a mapping of name to scenario")
    if len(scenarios) == 1:
        descriptor.setdefault("defaultScenario", next(iter(scenarios)))
    if descriptor.get("defaultScenario") not in scenarios:
        raise ValueError(
            f"{path}: defaultScenario {descriptor.get('defaultScenario')!r} "
            f"is not one of {', '.join(scenarios)}"
        )
    for name, scenario in scenarios.items():
        targets = scenario.get("kustomize") if isinstance(scenario, dict) else None
        if not isinstance(targets, list) or not targets:
            raise ValueError(
                f"{path}: scenario {name!r} must declare a list of Kustomize targets"
            )
    return descriptor


def discover():
    """Return {component: (chart directory, descriptor)} for every chart."""
    descriptors = {}
    for pattern in CHART_GLOBS:
        for chart in sorted(ROOT_DIRECTORY.glob(pattern)):
            path = chart / "ci" / "comparison.yaml"
            if not path.is_file():
                continue
            descriptor = load_descriptor(path)
            component = descriptor["component"]
            if component in descriptors:
                raise ValueError(f"{component!r} is declared twice: {path}")
            descriptors[component] = (chart, descriptor)
    return descriptors


def render_kustomize(scenario, destination):
    """Concatenate every Kustomize target this scenario compares against."""
    documents = [
        subprocess.run(
            ["kustomize", "build", str(ROOT_DIRECTORY / path)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        for path in scenario["kustomize"]
    ]
    destination.write_text(DOCUMENT_SEPARATOR.join(documents))


def render_helm(chart, descriptor, scenario, destination):
    command = ["helm", "template", descriptor["releaseName"], str(chart)]
    command += ["--namespace", descriptor["namespace"]]
    if descriptor.get("includeCustomResourceDefinitions"):
        command.append("--include-crds")
    if scenario.get("values"):
        command += ["--values", str(chart / scenario["values"])]
    destination.write_text(
        subprocess.run(command, check=True, capture_output=True, text=True).stdout
    )


def compare(component, name, descriptors, verbose):
    chart, descriptor = descriptors[component]
    scenario = descriptor["scenarios"][name]
    print(f"Comparing {component} manifests for scenario: {name}")

    if descriptor.get("dependencyRepositories"):
        for repository, url in descriptor["dependencyRepositories"].items():
            # Adding fails when the repository is already present, and its index
            # may be stale, so refresh it exactly as the previous harness did.
            if subprocess.run(
                ["helm", "repo", "add", repository, url], capture_output=True
            ).returncode:
                subprocess.run(
                    ["helm", "repo", "update", repository],
                    check=True,
                    capture_output=True,
                )
        subprocess.run(
            ["helm", "dependency", "build", str(chart)], check=True, capture_output=True
        )

    with tempfile.TemporaryDirectory() as directory:
        kustomize_output = Path(directory) / "kustomize.yaml"
        helm_output = Path(directory) / "helm.yaml"
        render_kustomize(scenario, kustomize_output)
        render_helm(chart, descriptor, scenario, helm_output)
        command = [
            sys.executable,
            str(COMPARATOR),
            str(kustomize_output),
            str(helm_output),
            component,
            name,
            descriptor["namespace"],
        ]
        if verbose:
            command.append("--verbose")
        return subprocess.run(command, cwd=ROOT_DIRECTORY).returncode == 0


def main():
    descriptors = discover()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("component", nargs="?", help="component to compare, or 'all'")
    parser.add_argument("scenario", nargs="?")
    parser.add_argument(
        "--verbose",
        action="store_true",
        default=os.environ.get("VERBOSE") == "true",
        help="print differing fields. Also enabled by VERBOSE=true.",
    )
    parser.add_argument(
        "--all-scenarios",
        action="store_true",
        help="compare every scenario the component declares, not just the default",
    )
    parser.add_argument(
        "--list", action="store_true", help="print every component and its scenarios"
    )
    arguments = parser.parse_args()

    if arguments.list:
        for component, (_, descriptor) in sorted(descriptors.items()):
            print(f"{component}: {' '.join(sorted(descriptor['scenarios']))}")
        return 0

    if not arguments.component:
        parser.error("a component is required, or 'all' to compare every component")

    if arguments.component != "all" and arguments.component not in descriptors:
        print(f"ERROR: Unknown component: {arguments.component}")
        print(f"Supported components: {', '.join(sorted(descriptors))}, all")
        return 1

    components = (
        sorted(descriptors) if arguments.component == "all" else [arguments.component]
    )
    failed = []
    for component in components:
        descriptor = descriptors[component][1]
        if arguments.scenario:
            if arguments.scenario not in descriptor["scenarios"]:
                print(f"ERROR: Unknown scenario: {arguments.scenario}")
                print(f"Supported scenarios: {', '.join(descriptor['scenarios'])}")
                return 1
            scenarios = [arguments.scenario]
        elif arguments.component == "all" or arguments.all_scenarios:
            scenarios = sorted(descriptor["scenarios"])
        else:
            scenarios = [descriptor["defaultScenario"]]

        for name in scenarios:
            if not compare(component, name, descriptors, arguments.verbose):
                print(f"FAILED: {component}/{name}")
                failed.append(f"{component}/{name}")

    if failed:
        print(f"FAILED: {', '.join(failed)}")
        return 1
    print(
        "SUCCESS: All components passed! Helm and Kustomize manifests are equivalent."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
