module github.com/kubeflow/community-distribution/tests/helm-release-size-encoder

// Helm v4.2.2, the version every Helm workflow pins, is built with this Go
// release. The encoder must compress with the same standard library that
// Helm's storage driver uses, so the toolchain is pinned here and installed
// from this file by actions/setup-go in the chart behavior job.
go 1.26.4
