.PHONY: build build-server build-client build-node build-linux \
       rootfs download-kernel run-server smoke release clean

BIN_DIR := ./bin
GO := go

build: build-server build-client build-node

build-server:
	$(GO) build -o $(BIN_DIR)/testnet-server ./cmd/testnet-server

build-client:
	$(GO) build -o $(BIN_DIR)/testnet-client ./cmd/testnet-client

build-node:
	$(GO) build -o $(BIN_DIR)/testnet-node ./cmd/testnet-node

build-linux:
	docker build --network=host -f Dockerfile.build -t agent-testnet-builder .
	@mkdir -p build-linux
	@CONTAINER_ID=$$(docker create --entrypoint="" agent-testnet-builder /bin/true) && \
	  docker cp $$CONTAINER_ID:/testnet-server build-linux/ && \
	  docker cp $$CONTAINER_ID:/testnet-client build-linux/ && \
	  docker cp $$CONTAINER_ID:/testnet-node   build-linux/ && \
	  docker rm $$CONTAINER_ID >/dev/null
	@echo "Linux binaries in build-linux/"

download-kernel:
	@mkdir -p ~/.testnet/bin
	curl -sSL "https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.10/x86_64/vmlinux-5.10.223" \
		-o ~/.testnet/bin/vmlinux-5.10.bin
	@echo "Kernel saved to ~/.testnet/bin/vmlinux-5.10.bin"

rootfs:
	sudo bash scripts/gen-rootfs.sh

run-server:
	$(BIN_DIR)/testnet-server --config ./configs/server.yaml

smoke: build
	@echo "Running smoke test..."
	bash scripts/smoke-test.sh

release:
	bash scripts/build-release.sh

release-rootfs:
	bash scripts/build-release.sh --rootfs

clean:
	rm -rf $(BIN_DIR) build-linux/ dist/ data/
