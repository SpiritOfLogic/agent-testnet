# Toolkit Quickstart for Node Developers

This guide covers how to download and use `testnet-toolkit` on your node. The toolkit handles TLS certificate fetching, domain discovery, and network sandboxing -- everything a node needs to integrate with the testnet without writing custom Go code.

## 1. Download the toolkit

Download the latest binary from the release and install it:

```bash
curl -fsSL https://github.com/SpiritOfLogic/agent-testnet/releases/latest/download/testnet-toolkit-linux-amd64 \
  -o /usr/local/bin/testnet-toolkit
chmod +x /usr/local/bin/testnet-toolkit
```

For arm64 hosts, replace `amd64` with `arm64`.

If you deploy using `install.sh` with the `node` role, the toolkit is installed automatically.

## 2. Fetch TLS certificates

Your node needs TLS certs signed by the testnet CA so agents trust it. The testnet operator will give you three values: the **server URL**, your **node name**, and your **node secret** (from `nodes.yaml`).

```bash
testnet-toolkit certs fetch \
  --server-url https://SERVER_IP:8443 \
  --name search \
  --secret YOUR_NODE_SECRET \
  --out-dir /etc/testnet/certs
```

This writes three files to `/etc/testnet/certs/`:

| File | Description |
|------|-------------|
| `cert.pem` | Your node's TLS certificate (includes SANs for `search.testnet`, `google.com`) |
| `key.pem` | Your node's TLS private key |
| `ca.pem` | The testnet root CA certificate |

Point your HTTPS server (nginx, Caddy, or your own binary) at `cert.pem` and `key.pem`. Use `ca.pem` when making outbound HTTPS requests to other testnet nodes.

Environment variables work too -- useful for systemd units or deploy scripts:

```bash
export SERVER_URL=https://SERVER_IP:8443
export NODE_NAME=search
export NODE_SECRET=YOUR_NODE_SECRET
testnet-toolkit certs fetch --out-dir /etc/testnet/certs
```

## 3. Discover testnet domains (for crawling)

To get a list of all domains on the testnet (excluding your own):

```bash
testnet-toolkit seed urls \
  --server-url https://SERVER_IP:8443 \
  --api-token YOUR_API_TOKEN \
  --exclude-node search
```

Output (one URL per line, ready to pipe into a crawler):

```
https://testnet.info/
https://pornhub.com/
```

Other output formats:

```bash
# Raw domain names
testnet-toolkit seed domains --server-url ... --api-token TOKEN

# JSON with VIP and node info
testnet-toolkit seed json --server-url ... --api-token TOKEN
```

## 4. Sandbox outbound traffic (optional)

If your node makes outbound HTTP requests (e.g., a crawler), run it inside the toolkit sandbox to ensure it can only reach testnet services:

```bash
sudo testnet-toolkit sandbox run \
  --dns-ip 10.100.0.1 \
  --ca-cert /etc/testnet/certs/ca.pem \
  -- /usr/local/bin/my-crawler --seeds /var/lib/seeds.txt
```

This creates a network namespace where only testnet VIPs are routable. Requires root and a WireGuard tunnel to be active.

## 5. Automate cert renewal

Certs expire after 1 year. Add a cron job or systemd timer:

```bash
# /etc/cron.d/testnet-certs
0 3 * * * root testnet-toolkit certs fetch --out-dir /etc/testnet/certs && systemctl reload your-service
```

## Quick reference

| Command | What it does |
|---------|-------------|
| `testnet-toolkit certs fetch` | Fetch TLS cert + key + CA from the control plane |
| `testnet-toolkit seed urls` | List all testnet URLs (for crawl seeds) |
| `testnet-toolkit seed domains` | List all testnet domain names |
| `testnet-toolkit seed json` | Full domain list as JSON |
| `testnet-toolkit sandbox run -- CMD` | Run a process confined to testnet network only |

## Further reading

- [Toolkit Reference](toolkit-reference.md) -- all flags, examples, error handling
- [Node Development Guide](node-development.md) -- architecture, API, and how nodes work
