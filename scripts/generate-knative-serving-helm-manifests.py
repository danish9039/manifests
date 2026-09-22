#!/usr/bin/env python3
"""Generate the Knative Serving payloads; three phase-boundary objects are hoisted.

The Namespace is retained. Image and Certificate instances wait until their APIs
and admission controllers are ready. Full-render parity covers those templates.
"""

import sys
from pathlib import Path

from helm_manifest_generator import GeneratorConfiguration, command_line

CONFIGURATION = GeneratorConfiguration(
    component_name="Knative Serving",
    kustomize_path=Path("common/knative/knative-serving/helm/kustomize"),
    output_path=Path("common/knative/knative-serving/helm/manifests"),
    generator_script="scripts/generate-knative-serving-helm-manifests.py",
    synchronize_script="scripts/synchronize-knative-manifests.sh",
    hand_written_resources=(
        ("Namespace", "knative-serving", False),
        ("Image", "queue-proxy", False),
        ("Certificate", "routing-serving-certs", False),
    ),
)

if __name__ == "__main__":
    sys.exit(command_line(CONFIGURATION, __doc__, Path(__file__).resolve().parents[1]))
