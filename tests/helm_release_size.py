#!/usr/bin/env python3
"""Measure the Secret storage every installable chart's release record needs.

Helm stores each release revision as one Kubernetes Secret whose data value is
base64(gzip(json(release))). The release JSON embeds the whole chart, every
template and file including the payloads read through .Files.Get, next to the
rendered manifest, the hooks and the values. Kubernetes refuses a Secret whose
data exceeds 1,048,576 bytes, so a chart that lints, packages and renders can
still be impossible to install. The KServe draft failed exactly this way on
2026-09-13 (workflow job 103766255179: 'Secret "sh.helm.release.v1.kserve.v1"
is invalid: data: Too long: may not be more than 1048576 bytes'). Neither the
packaged archive nor the rendered manifest predicts the stored size, and a
template switch that renders less does not help, because the chart files are
embedded whatever renders.

The record is produced by the Helm the workflows pin,
`helm install --dry-run=client --output=json`, and encoded by the Go helper
under tests/helm-release-size-encoder, which uses the standard library
packages Helm's storage driver uses. No Python compression stands in for it:
Go's deflate output is not byte-identical to zlib's.

Limitations. The record is generated on the client, without a cluster. It
differs from the record a live installation stores in info.status
(pending-install rather than deployed), info.description, the two timestamps
and the apply method, and it can differ in the rendered manifest wherever a
template draws on the cluster or on chance: `lookup` results, generated
passwords or certificates, capability checks. For the current charts that is
a few dozen bytes; a chart whose templates do such things must be measured
again from a live installation. This guard does not replace installing and
upgrading a chart on a cluster.

Every chart that declares ci/comparison.yaml is an installable unit, and each
of its scenarios is measured with that scenario's values file, which is the
complete installation configuration the comparison harness proves. A chart
that is only a dependency of another chart is not a unit and is never measured
on its own. A chart in a recognised location without a descriptor already
fails tests/comparison_descriptors_test.py; a chart in a location the harness
does not glob needs a discovery change before either check sees it.

Usage, from the repository root, with the Helm version the workflows pin:

    python3 tests/helm_release_size.py            every chart, every scenario
    python3 tests/helm_release_size.py istio      one component
    python3 tests/helm_release_size_test.py -v    the guard and its fixtures
"""

import argparse
import importlib.util
import os
import shlex
import shutil
import subprocess
import sys
import tempfile

from collections import namedtuple
from pathlib import Path

import yaml

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
ENCODER_SOURCE = Path(__file__).with_name("helm-release-size-encoder")
HARNESS_PATH = Path(__file__).with_name("run_helm_kustomize_comparison.py")
WORKFLOW_PATH = REPOSITORY_ROOT / ".github/workflows/helm-kustomize-comparison.yml"
_HARNESS_SPEC = importlib.util.spec_from_file_location(
    "run_helm_kustomize_comparison", HARNESS_PATH
)
harness = importlib.util.module_from_spec(_HARNESS_SPEC)
_HARNESS_SPEC.loader.exec_module(harness)

# core/v1 MaxSecretSize: the API server rejects a larger Secret outright.
MAX_SECRET_BYTES = 1_048_576
# A budget, not a limit: rows above it are reported so growth is noticed early.
WARNING_RATIO = 0.8
REQUIRED_HELM_MAJOR_VERSION = 4

Measurement = namedtuple(
    "Measurement", ("component", "scenario", "chart", "encoded_bytes", "command")
)


def run(command, **arguments):
    result = subprocess.run(command, capture_output=True, **arguments)
    if result.returncode:
        raise RuntimeError(
            f"{shlex.join(str(part) for part in command)} exited "
            f"{result.returncode}:\n{result.stderr.decode(errors='replace').strip()}"
        )
    return result.stdout


def helm_version():
    return run(["helm", "version", "--template", "{{.Version}}"]).decode().strip()


def require_helm_major_version(major):
    version = helm_version()
    found = version.lstrip("v").split(".", maxsplit=1)[0]
    if found != str(major):
        raise RuntimeError(
            f"Helm {major} is required, the version every workflow pins; "
            f"found {version}"
        )
    return version


def workflow_helm_version():
    """Return the Helm version the comparison workflow installs.

    Read from the workflow itself, so the pin has exactly one home.
    """
    workflow = yaml.safe_load(WORKFLOW_PATH.read_text())
    versions = {
        step["with"]["version"]
        for job in workflow["jobs"].values()
        for step in job.get("steps", [])
        if str(step.get("uses", "")).startswith("azure/setup-helm@")
    }
    if len(versions) != 1:
        raise RuntimeError(
            f"{WORKFLOW_PATH.name} pins {len(versions)} Helm versions; expected one"
        )
    return versions.pop()


def pinned_go_version():
    """Return the Go release go.mod pins, the release Helm is built with."""
    for line in (ENCODER_SOURCE / "go.mod").read_text().splitlines():
        if line.startswith("go "):
            return line.split()[1]
    raise RuntimeError(f"{ENCODER_SOURCE / 'go.mod'} declares no go directive")


def go_environment():
    """Make every go command use exactly the pinned release.

    GOTOOLCHAIN=go<version> selects that release even when a newer or older
    Go is installed, downloading it once if necessary, so the encoder is
    compiled with the same compress/gzip that Helm carries wherever it runs.
    """
    environment = dict(os.environ)
    environment["GOTOOLCHAIN"] = "go" + pinned_go_version()
    return environment


def go_version():
    return run(["go", "version"], env=go_environment()).decode().strip()


def toolchain_report():
    """Describe the toolchain in use and whether it matches the workflow.

    The encoder always runs on the pinned Go release. Helm is whatever is on
    PATH, so a version other than the workflow's is reported and the
    measurement described as approximate: another Helm release can serialise
    the record differently.
    """
    installed = require_helm_major_version(REQUIRED_HELM_MAJOR_VERSION)
    pinned = workflow_helm_version()
    report = f"helm {installed}, {go_version()}"
    if installed != pinned:
        report += (
            f"\nWARNING: the workflow pins Helm {pinned}; this measurement comes "
            f"from Helm {installed} and is approximate"
        )
    return report


def helm_environment(home):
    """Return an environment whose Helm state lives under `home` only.

    Repository indexes, downloaded dependencies and plugins then never touch
    the developer's own Helm directories, and the run cannot be influenced by
    them either.
    """
    environment = dict(os.environ)
    for variable in ("HELM_CACHE_HOME", "HELM_CONFIG_HOME", "HELM_DATA_HOME"):
        directory = Path(home) / variable.lower()
        directory.mkdir(parents=True, exist_ok=True)
        environment[variable] = str(directory)
    for variable in ("HELM_REPOSITORY_CONFIG", "HELM_REPOSITORY_CACHE", "HELM_PLUGINS"):
        environment.pop(variable, None)
    return environment


def build_encoder(directory):
    """Compile the Go encoder once; every measurement then runs the binary."""
    if shutil.which("go") is None:
        raise RuntimeError(
            "go is required to build tests/helm-release-size-encoder; install the "
            "Go release named in its go.mod"
        )
    binary = Path(directory) / "helm-release-size-encoder"
    run(
        ["go", "build", "-o", str(binary), "."],
        cwd=ENCODER_SOURCE,
        env=go_environment(),
    )
    return binary


def encoded_release_bytes(encoder, release_record):
    """Return the stored size of a release record, as the encoder reports it."""
    output = run([str(encoder)], input=release_record).decode()
    fields = dict(item.split("=", maxsplit=1) for item in output.split())
    return int(fields["encoded_bytes"])


def discover_units():
    """Return {component: (chart directory, descriptor)} for every installable chart."""
    descriptors = harness.discover()
    if not descriptors:
        raise RuntimeError(
            "no chart declares ci/comparison.yaml under "
            + ", ".join(harness.CHART_GLOBS)
        )
    for component, (chart, descriptor) in descriptors.items():
        if not descriptor["scenarios"]:
            raise RuntimeError(f"{component}: the descriptor declares no scenario")
    return descriptors


def prepare_chart(chart, descriptor, work_directory, environment):
    """Copy a chart and build its dependencies in the copy.

    The checkout, including any committed Chart.lock and any archives already
    under charts/, is never modified; the isolated Helm environment holds the
    repository indexes the dependencies are fetched from.
    """
    copy = Path(work_directory) / descriptor["component"]
    shutil.copytree(chart, copy, symlinks=True)
    for name, url in (descriptor.get("dependencyRepositories") or {}).items():
        run(["helm", "repo", "add", name, url], env=environment)
    metadata = yaml.safe_load((copy / "Chart.yaml").read_text()) or {}
    if metadata.get("dependencies"):
        run(["helm", "dependency", "build", str(copy)], env=environment)
    return copy


def dry_run_release(chart, descriptor, scenario, environment, *set_arguments):
    """Render one release record exactly as `helm install` would store it."""
    command = [
        "helm",
        "install",
        descriptor["releaseName"],
        str(chart),
        "--namespace",
        descriptor["namespace"],
        "--dry-run=client",
        "--output=json",
    ]
    if scenario.get("values"):
        command += ["--values", str(Path(chart) / scenario["values"])]
    for set_argument in set_arguments:
        command += ["--set", set_argument]
    return run(command, env=environment)


def reproduction_command(component):
    """The command that measures one component again, from the repository root.

    It compiles the encoder, prepares the chart's dependencies in a temporary
    copy and prints every scenario, which a bare `helm install` pipeline would
    not do: the encoder binary only exists for the duration of a run and the
    checkout may hold no built dependencies.
    """
    return shlex.join(["python3", "tests/helm_release_size.py", component])


def measure(descriptors, encoder, work_directory, environment):
    """Measure every scenario of every installable chart."""
    measurements = []
    for component, (chart, descriptor) in sorted(descriptors.items()):
        prepared = prepare_chart(chart, descriptor, work_directory, environment)
        for name, scenario in sorted(descriptor["scenarios"].items()):
            record = dry_run_release(prepared, descriptor, scenario, environment)
            measurements.append(
                Measurement(
                    component,
                    name,
                    str(chart.relative_to(REPOSITORY_ROOT)),
                    encoded_release_bytes(encoder, record),
                    reproduction_command(component),
                )
            )
    return measurements


def verdict(encoded_bytes):
    if encoded_bytes > MAX_SECRET_BYTES:
        return "FAIL"
    if encoded_bytes > MAX_SECRET_BYTES * WARNING_RATIO:
        return "WARNING"
    return "ok"


def format_table(measurements):
    width = (
        max(len(measurement.component) for measurement in measurements)
        if measurements
        else 9
    )
    scenario_width = (
        max(len(measurement.scenario) for measurement in measurements)
        if measurements
        else 8
    )
    lines = [
        f"{'component':<{width}}  {'scenario':<{scenario_width}}  "
        f"{'stored bytes':>12}  {'of limit':>8}  verdict"
    ]
    for measurement in measurements:
        lines.append(
            f"{measurement.component:<{width}}  "
            f"{measurement.scenario:<{scenario_width}}  "
            f"{measurement.encoded_bytes:>12,}  "
            f"{measurement.encoded_bytes / MAX_SECRET_BYTES:>7.1%}  "
            f"{verdict(measurement.encoded_bytes)}"
        )
    return "\n".join(lines)


def explain(measurement):
    return (
        f"{measurement.component} scenario {measurement.scenario} "
        f"({measurement.chart}) needs {measurement.encoded_bytes:,} bytes of "
        f"Secret storage, {measurement.encoded_bytes / MAX_SECRET_BYTES:.1%} of "
        f"the {MAX_SECRET_BYTES:,} byte limit; reproduce with: "
        f"{measurement.command}"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "component",
        nargs="*",
        help="measure only these components (default: every installable chart)",
    )
    arguments = parser.parse_args()

    print(toolchain_report())
    descriptors = discover_units()
    if arguments.component:
        unknown = set(arguments.component) - set(descriptors)
        if unknown:
            print(f"unknown component: {', '.join(sorted(unknown))}", file=sys.stderr)
            return 2
        descriptors = {name: descriptors[name] for name in arguments.component}

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        encoder = build_encoder(root)
        environment = helm_environment(root / "helm")
        measurements = measure(descriptors, encoder, root / "charts", environment)

    print(format_table(measurements))
    failed = False
    for measurement in measurements:
        if measurement.encoded_bytes > MAX_SECRET_BYTES:
            print("FAIL: " + explain(measurement), file=sys.stderr)
            failed = True
        elif measurement.encoded_bytes > MAX_SECRET_BYTES * WARNING_RATIO:
            print("WARNING: " + explain(measurement), file=sys.stderr)
    print(
        f"{len(measurements)} scenario releases across {len(descriptors)} charts "
        f"measured against {MAX_SECRET_BYTES:,} bytes"
    )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
