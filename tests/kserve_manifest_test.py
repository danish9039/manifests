#!/usr/bin/env python3

import json
import subprocess
import unittest
from pathlib import Path

import yaml

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]


def render_kustomization(kustomization_path):
    completed_process = subprocess.run(
        ["kustomize", "build", str(kustomization_path)],
        cwd=REPOSITORY_ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return [
        resource
        for resource in yaml.safe_load_all(completed_process.stdout)
        if resource is not None
    ]


def find_resource(resources, kind, name):
    for resource in resources:
        if resource.get("kind") != kind:
            continue
        if resource.get("metadata", {}).get("name") == name:
            return resource
    raise AssertionError(f"Missing {kind}/{name}")


class KServeManifestTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.kserve_resources = render_kustomization(
            REPOSITORY_ROOT / "applications/kserve/kserve"
        )
        cls.kserve_user_interface_resources = render_kustomization(
            REPOSITORY_ROOT / "applications/kserve/kserve-ui"
        )
        cls.kubeflow_namespace_resources = render_kustomization(
            REPOSITORY_ROOT / "common/kubeflow-namespace/base"
        )

    def test_control_plane_and_user_interface_namespaces(self):
        namespace = find_resource(self.kserve_resources, "Namespace", "kserve")
        self.assertEqual(namespace["metadata"]["name"], "kserve")
        self.assertEqual(
            namespace["metadata"]["labels"]["pod-security.kubernetes.io/enforce"],
            "restricted",
        )
        self.assertNotIn("istio-injection", namespace["metadata"]["labels"])

        for deployment_name in (
            "kserve-controller-manager",
            "kserve-localmodel-controller-manager",
            "llmisvc-controller-manager",
        ):
            deployment = find_resource(
                self.kserve_resources, "Deployment", deployment_name
            )
            self.assertEqual(deployment["metadata"].get("namespace"), "kserve")
            self.assertEqual(
                deployment["metadata"].get("labels", {}).get("control-plane"),
                deployment_name,
            )
            self.assertEqual(
                deployment["spec"]["template"]["metadata"]["annotations"][
                    "sidecar.istio.io/inject"
                ],
                "false",
            )

        for resource in self.kserve_resources:
            self.assertNotEqual(
                resource.get("metadata", {}).get("namespace"),
                "kubeflow",
                msg=(
                    f"{resource.get('kind')}/"
                    f"{resource.get('metadata', {}).get('name')} remains in kubeflow"
                ),
            )

        user_interface = find_resource(
            self.kserve_user_interface_resources,
            "Deployment",
            "kserve-models-web-application",
        )
        self.assertEqual(user_interface["metadata"].get("namespace"), "kserve")
        self.assertEqual(
            user_interface["spec"]["template"]["metadata"]["annotations"][
                "sidecar.istio.io/inject"
            ],
            "true",
        )
        self.assertEqual(
            user_interface["spec"]["template"]["metadata"]["labels"].get(
                "sidecar.istio.io/inject"
            ),
            "true",
        )

        cluster_role_binding = find_resource(
            self.kserve_user_interface_resources,
            "ClusterRoleBinding",
            "kserve-models-web-application-binding",
        )
        self.assertTrue(cluster_role_binding["subjects"])
        for subject in cluster_role_binding["subjects"]:
            self.assertEqual(subject.get("namespace"), "kserve")

        for resource in self.kserve_user_interface_resources:
            resource_kind = resource.get("kind", "")
            if resource_kind.startswith("Cluster"):
                continue
            self.assertEqual(
                resource.get("metadata", {}).get("namespace"),
                "kserve",
                msg=(
                    f"{resource_kind}/"
                    f"{resource.get('metadata', {}).get('name')} is not in kserve"
                ),
            )

    def test_storage_initializer_uses_restricted_security_context(self):
        storage_container = find_resource(
            self.kserve_resources, "ClusterStorageContainer", "default"
        )
        security_context = storage_container["spec"]["container"]["securityContext"]
        self.assertFalse(security_context["allowPrivilegeEscalation"])
        self.assertEqual(security_context["capabilities"]["drop"], ["ALL"])
        self.assertTrue(security_context["runAsNonRoot"])
        self.assertEqual(security_context["runAsUser"], 1000)
        self.assertEqual(
            security_context["seccompProfile"]["type"],
            "RuntimeDefault",
        )

    def test_user_interface_route_and_network_policy_use_kserve_namespace(self):
        virtual_service = find_resource(
            self.kserve_user_interface_resources,
            "VirtualService",
            "kserve-models-web-application",
        )
        self.assertEqual(
            virtual_service["spec"]["gateways"],
            ["kubeflow/kubeflow-gateway"],
        )
        destination = virtual_service["spec"]["http"][0]["route"][0]["destination"]
        self.assertEqual(
            destination["host"],
            "kserve-models-web-application.kserve.svc.cluster.local",
        )

        network_policy = find_resource(
            self.kserve_user_interface_resources,
            "NetworkPolicy",
            "kserve-models-web-application",
        )
        self.assertEqual(network_policy["metadata"]["namespace"], "kserve")

        kubeflow_network_policies = {
            resource.get("metadata", {}).get("name")
            for resource in self.kubeflow_namespace_resources
            if resource.get("kind") == "NetworkPolicy"
        }
        self.assertNotIn(
            "kserve-models-web-application",
            kubeflow_network_policies,
        )

    def test_cluster_scoped_resources_have_no_namespace(self):
        explicitly_cluster_scoped_kinds = {
            "CustomResourceDefinition",
            "MutatingWebhookConfiguration",
            "Namespace",
            "ValidatingWebhookConfiguration",
        }

        for resource in self.kserve_resources:
            resource_kind = resource.get("kind", "")
            if not (
                resource_kind.startswith("Cluster")
                or resource_kind in explicitly_cluster_scoped_kinds
            ):
                continue

            self.assertNotIn(
                "namespace",
                resource.get("metadata", {}),
                msg=(
                    f"{resource_kind}/"
                    f"{resource.get('metadata', {}).get('name')} is cluster-scoped"
                ),
            )

    def test_disabled_local_model_node_agent_has_no_resources(self):
        forbidden_resources = {
            ("DaemonSet", "kserve-localmodelnode-agent"),
            ("ServiceAccount", "kserve-localmodelnode-agent"),
            ("ClusterRole", "kserve-localmodelnode-agent-role"),
            ("ClusterRoleBinding", "kserve-localmodelnode-agent-rolebinding"),
        }
        rendered_resources = {
            (resource.get("kind"), resource.get("metadata", {}).get("name"))
            for resource in self.kserve_resources
        }
        self.assertFalse(forbidden_resources & rendered_resources)

    def test_aggregate_roles_do_not_expand_llm_configuration_access(self):
        for cluster_role_name in ("kubeflow-kserve-edit", "kubeflow-kserve-view"):
            cluster_role = find_resource(
                self.kserve_resources, "ClusterRole", cluster_role_name
            )
            serving_resources = {
                resource_name
                for rule in cluster_role.get("rules", [])
                if "serving.kserve.io" in rule.get("apiGroups", [])
                for resource_name in rule.get("resources", [])
            }
            self.assertNotIn("llminferenceserviceconfigs", serving_resources)

    def test_webhook_certificates_and_ca_injection_use_kserve_namespace(self):
        for certificate_name in (
            "serving-cert",
            "llmisvc-serving-cert",
            "localmodel-serving-cert",
        ):
            certificate = find_resource(
                self.kserve_resources, "Certificate", certificate_name
            )
            self.assertEqual(certificate["metadata"].get("namespace"), "kserve")
            self.assertTrue(
                all(
                    dns_name.endswith(".kserve.svc")
                    for dns_name in certificate["spec"].get("dnsNames", [])
                )
            )

        annotated_resources = [
            resource
            for resource in self.kserve_resources
            if resource.get("metadata", {})
            .get("annotations", {})
            .get("cert-manager.io/inject-ca-from")
        ]
        self.assertTrue(annotated_resources)
        for resource in annotated_resources:
            ca_source = resource["metadata"]["annotations"][
                "cert-manager.io/inject-ca-from"
            ]
            self.assertTrue(ca_source.startswith("kserve/"))

        webhook_service_references = []
        for resource in self.kserve_resources:
            if resource.get("kind") in (
                "MutatingWebhookConfiguration",
                "ValidatingWebhookConfiguration",
            ):
                webhook_service_references.extend(
                    webhook.get("clientConfig", {}).get("service")
                    for webhook in resource.get("webhooks", [])
                )

            if resource.get("kind") == "CustomResourceDefinition":
                webhook_service_references.append(
                    resource.get("spec", {})
                    .get("conversion", {})
                    .get("webhook", {})
                    .get("clientConfig", {})
                    .get("service")
                )

        webhook_service_references = [
            service_reference
            for service_reference in webhook_service_references
            if service_reference
        ]
        self.assertTrue(webhook_service_references)
        for service_reference in webhook_service_references:
            self.assertEqual(service_reference.get("namespace"), "kserve")

    def test_inference_service_configuration_preserves_kubeflow_gateway(self):
        configuration = find_resource(
            self.kserve_resources, "ConfigMap", "inferenceservice-config"
        )
        self.assertEqual(configuration["metadata"].get("namespace"), "kserve")

        ingress_configuration = json.loads(configuration["data"]["ingress"])
        self.assertEqual(
            ingress_configuration["ingressGateway"], "kubeflow/kubeflow-gateway"
        )
        self.assertEqual(
            ingress_configuration["pathTemplate"],
            "/serving/{{ .Namespace }}/{{ .Name }}",
        )

    def test_upgrade_documentation_covers_relocation_cleanup(self):
        resources_to_clean_up = (
            "kserve-localmodelnode-agent-role",
            "kserve-localmodelnode-agent-rolebinding",
            "kserve-controller-manager-leader-lock",
            "llminferenceservice-kserve-controller-manager",
            "deployment/kserve-models-web-application",
            "service/kserve-models-web-application",
            "serviceaccount/kserve-models-web-application",
            "configmap/kserve-models-web-application-config",
            "virtualservice.networking.istio.io/kserve-models-web-application",
            "authorizationpolicy.security.istio.io/kserve-models-web-application",
            "networkpolicy.networking.k8s.io/kserve-models-web-application",
        )

        for documentation_path in (
            REPOSITORY_ROOT / "README.md",
            REPOSITORY_ROOT / "applications/kserve/README.md",
        ):
            with self.subTest(documentation_path=documentation_path):
                documentation = documentation_path.read_text()
                for resource_name in resources_to_clean_up:
                    self.assertIn(resource_name, documentation)
                self.assertIn("--replicas=0", documentation)
                self.assertNotIn(
                    "keep the old control plane available while applying",
                    documentation.lower(),
                )

    def test_kustomize_comments_describe_current_kserve_resources(self):
        kustomization = (
            REPOSITORY_ROOT / "applications/kserve/kserve/kustomization.yaml"
        ).read_text()

        for inaccurate_statement in (
            "Runs as privileged: true",
            "runAsNonRoot: false",
            "Webhook server for llmisvcconfig is not running",
        ):
            self.assertNotIn(inaccurate_statement, kustomization)

    def test_user_interface_chart_network_policy_defaults_are_safe(self):
        chart_directory = REPOSITORY_ROOT / "experimental/helm/charts/kserve-ui"
        default_values = yaml.safe_load((chart_directory / "values.yaml").read_text())
        kubeflow_values = yaml.safe_load(
            (chart_directory / "ci/kubeflow-values.yaml").read_text()
        )

        self.assertFalse(default_values["networkPolicy"]["enabled"])
        self.assertTrue(kubeflow_values["networkPolicy"]["enabled"])
        self.assertEqual(
            kubeflow_values["networkPolicy"]["ingress"][0]["from"][0][
                "namespaceSelector"
            ]["matchExpressions"][0]["values"],
            ["istio-system"],
        )

    def test_existing_helm_release_namespace_migration_is_documented(self):
        chart_readme = (
            REPOSITORY_ROOT / "experimental/helm/charts/kserve-ui/README.md"
        ).read_text()

        for required_command in (
            "helm upgrade --install kubeflow-namespaces",
            "helm uninstall kserve-models-web-application --namespace kubeflow",
            "networkpolicy.networking.k8s.io/kserve-models-web-application",
            "helm install kserve-models-web-application",
            "--namespace kserve",
        ):
            self.assertIn(required_command, chart_readme)

    def test_user_interface_synchronization_updates_chart_application_version(self):
        synchronization_script = (
            REPOSITORY_ROOT / "scripts/synchronize-kserve-ui-manifests.sh"
        ).read_text()

        self.assertIn(
            "update_helm_chart_application_version",
            synchronization_script,
        )
        self.assertIn(
            '"${MANIFESTS_DIRECTORY}/experimental/helm/charts/'
            '${COMPONENT_NAME}/Chart.yaml" "$COMMIT"',
            synchronization_script,
        )


if __name__ == "__main__":
    unittest.main()
