#!/usr/bin/env python3
"""Generate the Kubeflow Dashboard Helm chart payloads.

Component-specific configuration only. The parsing, validation, custom resource
definition retention, deterministic rendering and atomic replacement live in
scripts/helm_manifest_generator.py so every component shares one engine.
"""

import importlib.util
import sys

from pathlib import Path

ENGINE_PATH = Path(__file__).resolve().parent / "helm_manifest_generator.py"
_SPEC = importlib.util.spec_from_file_location("helm_manifest_generator", ENGINE_PATH)
engine = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(engine)


CONFIGURATION = engine.GeneratorConfiguration(
    component_name="Dashboard",
    kustomize_path=Path("applications/dashboard/helm/kustomize"),
    output_path=Path("applications/dashboard/helm/manifests"),
    generator_script="scripts/generate-dashboard-helm-manifests.py",
    synchronize_script="scripts/synchronize-dashboard-manifests.sh",
    # Resources rendered by hand-written Helm templates so that the values
    # Kustomize already declares - container images and configMapGenerator
    # inputs - can be exposed through values.yaml. They are excluded from the
    # generated payloads. A prefixed entry matches the content-hash suffix
    # Kustomize appends to generated ConfigMap names.
    hand_written_resources=(
        ("Deployment", "dashboard", False),
        ("Deployment", "poddefaults-webhook-deployment", False),
        ("Deployment", "profiles-deployment", False),
        ("ConfigMap", "dashboard-config", False),
        ("ConfigMap", "dashboard-parameters-", True),
        ("ConfigMap", "profiles-config-", True),
        ("ConfigMap", "profiles-namespace-labels-data-", True),
    ),
    # Embedded documents extracted verbatim so a hand-written template can
    # inherit the upstream content byte for byte while still allowing an
    # override through values.yaml.
    extracted_documents=(
        ("ConfigMap", "dashboard-config", False, "links", "dashboard-links.json"),
        (
            "ConfigMap",
            "dashboard-config",
            False,
            "settings",
            "dashboard-settings.json",
        ),
        (
            "ConfigMap",
            "profiles-namespace-labels-data-",
            True,
            "namespace-labels.yaml",
            "profile-namespace-labels.yaml",
        ),
    ),
)


def main():
    return engine.command_line(
        CONFIGURATION,
        description="Generate payloads for the Kubeflow Dashboard Helm chart.",
        default_repository_root=Path(__file__).resolve().parents[1],
    )


if __name__ == "__main__":
    sys.exit(main())
