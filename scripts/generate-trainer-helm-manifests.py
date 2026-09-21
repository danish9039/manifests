#!/usr/bin/env python3
"""Generate three disjoint Trainer releases through the shared payload engine.

The API dependency is internal packaging, not a fourth installed release.
Each chart is replaced atomically; --check never writes any of the charts.
"""

import importlib.util
import sys
from pathlib import Path

ENGINE_PATH = Path(__file__).resolve().parent / "helm_manifest_generator.py"
SPEC = importlib.util.spec_from_file_location("helm_manifest_generator", ENGINE_PATH)
engine = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(engine)

DEFINITIONS = ("apiextensions.k8s.io", "CustomResourceDefinition")
RUNTIMES = ("trainer.kubeflow.org", "ClusterTrainingRuntime")
COMMON = dict(
    kustomize_path=Path("applications/trainer/overlays"),
    generator_script="scripts/generate-trainer-helm-manifests.py",
    synchronize_script="scripts/synchronize-trainer-manifests.sh",
)
CONFIGURATIONS = (
    engine.GeneratorConfiguration(
        **COMMON,
        component_name="Trainer APIs",
        output_path=Path(
            "applications/trainer/helm-crds/charts/trainer-api-payload/manifests"
        ),
        included_resource_kinds=(DEFINITIONS,),
        crds_payload_directory="definitions",
        resources_payload_filename=None,
    ),
    engine.GeneratorConfiguration(
        **COMMON,
        component_name="Trainer control plane",
        output_path=Path("applications/trainer/helm/manifests"),
        excluded_resource_kinds=(DEFINITIONS, RUNTIMES),
        crds_payload_filename=None,
    ),
    engine.GeneratorConfiguration(
        **COMMON,
        component_name="Trainer runtimes",
        output_path=Path("applications/trainer/helm-runtimes/manifests"),
        included_resource_kinds=(RUNTIMES,),
        crds_payload_filename=None,
    ),
)


def main():
    for configuration in CONFIGURATIONS:
        status = engine.command_line(
            configuration,
            "Generate the three Trainer chart payloads.",
            Path(__file__).resolve().parents[1],
        )
        if status:
            return status
    return 0


if __name__ == "__main__":
    sys.exit(main())
