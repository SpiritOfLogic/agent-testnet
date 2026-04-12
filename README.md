# Agent Testnet

A sandboxed internet environment for AI agents. Agents run inside Firecracker microVMs with network isolation enforced via WireGuard tunnels, interacting only with operator-declared testnet nodes.

## Architecture

```
                    +-----------------+
                    | testnet-server  |
                    |  Control Plane  |
                    |  DNS + WG + NAT |
                    +--------+--------+
                             |
                     WireGuard tunnel
                             |
          +------------------+------------------+
          |                                     |
+---------+----------+              +-----------+--------+
| testnet-client     |              | testnet-node       |
| Firecracker VMs    |              | (any service)      |
| iptables isolation |              | TLS via testnet CA |
+--------------------+              +--------------------+
```

- **testnet-server** -- Control plane: client registration, DNS (VIP-based), WireGuard hub, iptables DNAT routing
- **testnet-client** -- Agent sandbox: Firecracker VM management, per-VM ephemeral SSH keys, network isolation via iptables
- **testnet-node** -- Any service exposed to agents; fetches TLS certs from the server's CA

## One-Command Deployment

Each role deploys to a fresh Linux host with a single command. Binaries are pre-placed at `/usr/local/bin/` or downloaded from a release URL.

### Server

```bash
NODES_YAML='nodes:
  - name: node1
    address: "NODE_IP:443"
    secret: "shared-secret"
    domains: ["google.com", "www.google.com"]
' sudo -E bash install.sh server
```

Installs deps, writes config, starts the service, and prints the join token.

### Node

```bash
SERVER_URL=https://SERVER_IP:8443 NODE_NAME=node1 NODE_SECRET=shared-secret \
  sudo -E bash install.sh node
```

Installs the binary, writes `/etc/testnet/node.env`, starts the service.

### Client

```bash
SERVER_URL=https://SERVER_IP:8443 JOIN_TOKEN=<token> \
  sudo -E bash install.sh client
```

Installs deps, downloads Firecracker + kernel, registers with the server, brings up the WireGuard tunnel, and builds a lean Alpine rootfs (~512 MB). Optionally set `ROOTFS_URL` to download a pre-built rootfs instead.

Then launch an agent VM:

```bash
sudo testnet-client agent launch --standalone
```

The rootfs ships with bash, curl, git, jq, and SSH. Agents can install additional runtimes inside the VM via `apk add` (e.g. `apk add nodejs npm python3`).

## Local Development

```bash
# Build all binaries
make build

# Run the server locally (requires root for WireGuard + iptables)
make run-server

# Cross-compile Linux amd64 binaries via Docker
make build-linux

# Build the agent rootfs (requires root + Linux)
make rootfs

# Run API-level smoke tests
make smoke
```

## Network Model

- Each declared domain gets a Virtual IP (VIP) in `10.100.0.0/16`
- Testnet DNS resolves declared domains to VIPs; returns NXDOMAIN for undeclared domains
- WireGuard tunnel (`10.99.0.0/16`) is the sole egress path from agent VMs
- Server-side iptables DNAT maps VIPs to real node IPs
- Agent VMs are isolated: only VIP traffic is forwarded, all other egress is dropped

## Security

- **No hardcoded passwords**: VM rootfs uses key-only SSH auth (`PasswordAuthentication no`)
- **Ephemeral SSH keys**: Each VM gets a unique ed25519 keypair generated at launch; the private key is stored at `~/.testnet/data/agents/<id>/ssh_key`
- **Per-VM rootfs**: The base rootfs image is copied per-VM to prevent cross-VM interference
- **CA cert injection**: The testnet CA certificate is injected into each VM at launch via rootfs mount
- **Network isolation**: iptables rules on the client host drop all traffic from VMs except to testnet VIPs

## Project Structure

```
cmd/                    Entry points for the three binaries
  testnet-server/
  testnet-client/
  testnet-node/
server/                 Server-side packages
  controlplane/         Registration, CA, VIP allocation
  dns/                  Testnet DNS server
  router/               iptables DNAT + traffic logging
  wg/                   WireGuard endpoint management
client/                 Client-side packages
  cli/                  CLI commands (setup, install, agent, daemon)
  daemon/               Background daemon + agent VM lifecycle
  sandbox/              Firecracker VM + network isolation
pkg/                    Shared packages
  api/                  API types + HTTP client
  config/               Config structs + loading
configs/                Example configs (local development)
deploy/
  install.sh            Universal installer (one-command deployment)
scripts/
  gen-rootfs.sh         Builds the Alpine-based agent rootfs (lean: bash, curl, git, jq)
  build-release.sh      Cross-compiles release artifacts
  smoke-test.sh         API-level smoke test suite
docs/
  testnet_mvp_design.md Architecture design document
```

## Network Requirements

The following ports must be open on the **server** host:

| Port | Protocol | Purpose |
|------|----------|---------|
| 8443 | TCP | Control plane API (HTTPS) |
| 51820 | **UDP** | WireGuard tunnel |
| 5353 | UDP/TCP | DNS (public listener) |

**Important:** Many hosting providers (IONOS, OVH, etc.) have a platform-level firewall that blocks UDP by default, separate from `iptables` on the server. If clients register successfully but the WireGuard tunnel never establishes (0 bytes received), open UDP 51820 in your provider's firewall dashboard.

The **node** needs TCP 443 (or whichever port it listens on) open for inbound HTTPS.

The **client** needs outbound UDP 51820 to the server (typically open by default).

If your hosting provider cannot open UDP ports at all, you can wrap WireGuard in a TCP tunnel using [udp2raw](https://github.com/wangyu-/udp2raw) or [wstunnel](https://github.com/erebe/wstunnel). See their documentation for setup.

## Requirements

- Go 1.25+ (for building from source)
- Linux with `/dev/kvm` (for Firecracker on the client)
- Root access (for iptables, WireGuard, Firecracker)
- Docker (for cross-compilation from macOS)

## License

MIT
