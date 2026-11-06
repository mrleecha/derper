IMAGE ?= derper
TAG ?= dev

BUILD_ARGS =
ifneq ($(TAILSCALE_VERSION),)
BUILD_ARGS += --build-arg TAILSCALE_VERSION=$(TAILSCALE_VERSION)
endif

.PHONY: build test check shell

build:
	docker build $(BUILD_ARGS) -t $(IMAGE):$(TAG) .

test: check
	IMAGE=$(IMAGE):smoke ./test/smoke.sh

check:
	sh -n entrypoint.sh
	sh -n test/smoke.sh

shell:
	docker run --rm -it --entrypoint /bin/sh $(IMAGE):$(TAG)
