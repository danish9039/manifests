#!/usr/bin/env python3
"""Generate the distribution Models UI Helm payload through the shared engine.

The complete source render is retained, including its hashed ConfigMap name
and matching Deployment reference. Authentication and routing stay coupled.
"""

import importlib.util
import sys

from pathlib import Path

ENGINE_PATH = Path(__file__).resolve().parent / "helm_manifest_generator.py"
_SPEC = importlib.util.spec_from_file_location("helm_manifest_generator", ENGINE_PATH)
engine = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(engine)

CONFIGURATION = engine.GeneratorConfiguration(
    component_name="Models UI",
    crds_payload_filename=None,
    # A wrapper beneath helm/ cannot include its parent component: Kustomize
    # rejects revisiting that root. Render the owning component directly.
    kustomize_path=Path("applications/kserve/kserve-ui"),
    output_path=Path("applications/kserve/kserve-ui/helm/manifests"),
    generator_script="scripts/generate-kserve-ui-helm-manifests.py",
    synchronize_script="scripts/synchronize-kserve-ui-manifests.sh",
)


def main():
    return engine.command_line(
        CONFIGURATION,
        description="Generate payloads for the distribution Models UI Helm chart.",
        default_repository_root=Path(__file__).resolve().parents[1],
    )


if __name__ == "__main__":
    sys.exit(main())
