# KServe

For KServe installation and usage, see the [GitHub Actions tests](.github/workflows/kserve_test.yaml) which demonstrate working configurations.

For complete documentation, visit the [official KServe website](https://kserve.github.io/website/).

## Integration with KubeFlow

The KServe control plane and Models Web Application are installed in the
`kserve` namespace. The Models Web Application remains available through the
Kubeflow gateway at `/kserve-endpoints/`.

When using KServe with path-based routing in a KubeFlow deployment, you may encounter VirtualService conflicts that result in 404 errors when accessing KServe InferenceServices.

**Common Issues:**
- KServe InferenceServices return 404 errors when accessed via their configured domain
- Conflicts between KubeFlow's wildcard VirtualServices and KServe's specific-host VirtualServices

**Solution:** See the [Istio troubleshooting guide](../../common/istio/README.md#virtualservice-conflicts-with-kserve-path-based-routing) for detailed resolution steps.

**Related Documentation:**
- [KServe Path-Based Routing Configuration](https://kserve.github.io/website/docs/admin-guide/configurations#path-template)
- [Upstream Istio Issue](https://github.com/istio/istio/issues/57404)

## Upgrade Cleanup

When upgrading from a version that installed KServe control-plane resources in
the `kubeflow` namespace, plan for a short control-plane interruption. Do not
delete KServe CRDs, user `InferenceService` objects, or profile namespaces.

The standard upstream bundle also uses the current upstream workload labels.
Update custom monitoring and policies that select the legacy `app: kserve` pod
label to select the `control-plane` label instead.

First remove the unused cluster-scoped authorization for the disabled local
model node agent:

```sh
kubectl delete --ignore-not-found \
  clusterrolebinding/kserve-localmodelnode-agent-rolebinding \
  clusterrole/kserve-localmodelnode-agent-role
```

Before applying the new manifests, scale the old controllers to zero.
Controllers in different namespaces use different leader-election Leases and
must not run concurrently:

```sh
kubectl scale -n kubeflow --replicas=0 \
  deployment/kserve-controller-manager \
  deployment/kserve-localmodel-controller-manager \
  deployment/llmisvc-controller-manager
```

Remove the old Models Web Application route before applying the new manifests
so the old and new VirtualServices do not claim `/kserve-endpoints/`
concurrently. Then remove the remaining old namespaced resources:

```sh
kubectl delete -n kubeflow --ignore-not-found \
  virtualservice.networking.istio.io/kserve-models-web-application
kubectl delete -n kubeflow --ignore-not-found \
  serviceaccount/kserve-models-web-application \
  configmap/kserve-models-web-application-config \
  service/kserve-models-web-application \
  deployment/kserve-models-web-application \
  authorizationpolicy.security.istio.io/kserve-models-web-application \
  networkpolicy.networking.k8s.io/kserve-models-web-application
```

Apply the new release manifests using the normal upgrade procedure. Then verify
the new KServe controllers, Models Web Application, certificates, and webhook
endpoints in the `kserve` namespace:

```sh
kubectl rollout status -n kserve --timeout=120s \
  deployment/kserve-controller-manager \
  deployment/kserve-localmodel-controller-manager \
  deployment/llmisvc-controller-manager \
  deployment/kserve-models-web-application
kubectl wait -n kserve --for=condition=Ready --timeout=120s \
  certificate.cert-manager.io/serving-cert \
  certificate.cert-manager.io/llmisvc-serving-cert \
  certificate.cert-manager.io/localmodel-serving-cert
kubectl get endpoints -n kserve \
  kserve-webhook-server-service \
  llmisvc-webhook-server-service \
  localmodel-webhook-server-service
```

After the new control plane is ready, delete the old `kubeflow`-scoped
resources:

```sh
kubectl delete -n kubeflow --ignore-not-found \
  serviceaccount/kserve-controller-manager \
  serviceaccount/kserve-localmodel-controller-manager \
  serviceaccount/kserve-localmodelnode-agent \
  serviceaccount/llmisvc-controller-manager \
  networkpolicy.networking.k8s.io/kserve \
  role.rbac.authorization.k8s.io/kserve-leader-election-role \
  role.rbac.authorization.k8s.io/llmisvc-leader-election-role \
  rolebinding.rbac.authorization.k8s.io/kserve-leader-election-rolebinding \
  rolebinding.rbac.authorization.k8s.io/llmisvc-leader-election-rolebinding \
  configmap/inferenceservice-config \
  secret/kserve-webhook-server-secret \
  secret/kserve-webhook-server-cert \
  secret/llmisvc-webhook-server-cert \
  secret/localmodel-webhook-server-cert \
  service/kserve-controller-manager-metrics-service \
  service/kserve-controller-manager-service \
  service/kserve-webhook-server-service \
  service/llmisvc-controller-manager-service \
  service/llmisvc-webhook-server-service \
  service/localmodel-webhook-server-service \
  deployment.apps/kserve-controller-manager \
  deployment.apps/kserve-localmodel-controller-manager \
  deployment.apps/llmisvc-controller-manager \
  daemonset.apps/kserve-localmodelnode-agent \
  lease.coordination.k8s.io/kserve-controller-manager-leader-lock \
  lease.coordination.k8s.io/llminferenceservice-kserve-controller-manager \
  certificate.cert-manager.io/serving-cert \
  certificate.cert-manager.io/llmisvc-serving-cert \
  certificate.cert-manager.io/localmodel-serving-cert \
  issuer.cert-manager.io/selfsigned-issuer
```
