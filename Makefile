.PHONY: verify verify-runtime verify-runtime-kfp verify-runtime-katib setup-kind-prereqs preload-kind-images

verify:
	./gsoc-poc/scripts/verify-parity.sh

verify-runtime:
	$(MAKE) verify-runtime-kfp
	$(MAKE) verify-runtime-katib

verify-runtime-kfp:
	./gsoc-poc/scripts/verify-runtime.sh both

verify-runtime-katib:
	./gsoc-poc/scripts/verify-runtime-katib.sh both

setup-kind-prereqs:
	./gsoc-poc/scripts/setup-kind-prereqs.sh

preload-kind-images:
	./gsoc-poc/scripts/preload-kind-images.sh
