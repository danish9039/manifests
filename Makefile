.PHONY: verify verify-runtime setup-kind-prereqs

verify:
	./gsoc-poc/scripts/verify-parity.sh

verify-runtime:
	./gsoc-poc/scripts/verify-runtime.sh both

setup-kind-prereqs:
	./gsoc-poc/scripts/setup-kind-prereqs.sh
