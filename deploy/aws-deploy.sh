#!/usr/bin/env bash
#
# Deploy Agent Testnet to AWS using the AWS CLI.
#
# Usage:
#   bash deploy/aws-deploy.sh deploy          # Create infrastructure + deploy
#   bash deploy/aws-deploy.sh teardown        # Destroy all resources
#   bash deploy/aws-deploy.sh status          # Show instance IPs and status
#   bash deploy/aws-deploy.sh ssh <role>      # SSH into server|node|client
#   bash deploy/aws-deploy.sh restart <role>  # Restart a service (server|node|client)
#   bash deploy/aws-deploy.sh redeploy <role> # Rebuild, upload & restart (server|node|client)
#   bash deploy/aws-deploy.sh reload          # Push updated nodes.yaml + reload server
#   bash deploy/aws-deploy.sh test            # Run integration test on client VM
#   bash deploy/aws-deploy.sh openclaw [sub]  # Install/run OpenClaw in an agent VM
#
# OpenClaw subcommands:
#   bash deploy/aws-deploy.sh openclaw install --api-key KEY [--provider anthropic|openai|xai|openrouter]
#   bash deploy/aws-deploy.sh openclaw chat      # Interactive chat with OpenClaw
#   bash deploy/aws-deploy.sh openclaw status    # Check OpenClaw + VM status
#   bash deploy/aws-deploy.sh openclaw stop      # Stop OpenClaw, proxies, and the VM
#   bash deploy/aws-deploy.sh openclaw reconfig --api-key KEY --provider openrouter --model anthropic/claude-3.5-haiku
#
# Prerequisites:
#   - AWS CLI configured (aws sts get-caller-identity)
#   - Go 1.25+ (binaries are cross-compiled automatically if missing)
#   - deploy/install.sh present
#
# Resources are tagged with testnet-stack=agent-testnet for easy identification
# and cleanup. A state file (deploy/.aws-state.json) tracks all created
# resource IDs for teardown.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STATE_FILE="${SCRIPT_DIR}/.aws-state.json"
DIST_DIR="${PROJECT_DIR}/dist"

REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo "eu-west-1")}"
STACK_TAG="testnet-stack"
STACK_VALUE="agent-testnet"

INSTANCE_TYPE_SERVER="${INSTANCE_TYPE_SERVER:-t3a.nano}"
INSTANCE_TYPE_NODE="${INSTANCE_TYPE_NODE:-t3a.nano}"
INSTANCE_TYPE_CLIENT="${INSTANCE_TYPE_CLIENT:-m8i-flex.large}"

NODES_YAML_SRC="${PROJECT_DIR}/configs/nodes.yaml"
NODE_SECRET="$(head -c 16 /dev/urandom | base64 | tr -d '/+=' | head -c 24)"

# ---- helpers ----

info()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33mWARN:\033[0m %s\n" "$*"; }
err()   { printf "\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }

tag_spec() {
    echo "ResourceType=$1,Tags=[{Key=${STACK_TAG},Value=${STACK_VALUE}},{Key=Name,Value=testnet-$2}]"
}

save_state() {
    local key="$1" value="$2"
    if [ ! -f "$STATE_FILE" ]; then
        echo '{}' > "$STATE_FILE"
    fi
    local tmp="${STATE_FILE}.tmp"
    python3 -c "
import json, sys
with open('$STATE_FILE') as f:
    state = json.load(f)
state['$key'] = '$value'
with open('$tmp', 'w') as f:
    json.dump(state, f, indent=2)
"
    mv "$tmp" "$STATE_FILE"
}

load_state() {
    local key="$1"
    if [ ! -f "$STATE_FILE" ]; then
        echo ""
        return
    fi
    python3 -c "
import json
with open('$STATE_FILE') as f:
    state = json.load(f)
print(state.get('$key', ''))
"
}

wait_for_ssh() {
    local ip="$1"
    local key="$2"
    local max_attempts=40
    local attempt=0
    info "Waiting for SSH on ${ip}..."
    while [ $attempt -lt $max_attempts ]; do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
            -i "$key" "ubuntu@${ip}" "echo ready" >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 5
    done
    err "SSH to ${ip} timed out after $((max_attempts * 5))s"
}

remote_exec() {
    local ip="$1"
    local key="$2"
    shift 2
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes -i "$key" "ubuntu@${ip}" "$@"
}

remote_copy() {
    local key="$1"
    local src="$2"
    local dest="$3"
    scp -o StrictHostKeyChecking=no -o BatchMode=yes -i "$key" "$src" "$dest"
}

# ---- deploy ----

do_deploy() {
    info "Deploying Agent Testnet to AWS (${REGION})"

    # Preflight
    [ -f "${SCRIPT_DIR}/install.sh" ] || err "Missing deploy/install.sh"
    if [ ! -f "$NODES_YAML_SRC" ]; then
        err "Missing ${NODES_YAML_SRC}. Copy the example and edit it:
  cp configs/nodes.yaml.example configs/nodes.yaml"
    fi
    aws sts get-caller-identity >/dev/null 2>&1 || err "AWS CLI not configured"

    # Extract the first node name from the config file
    local NODE_NAME
    NODE_NAME=$(grep -m1 'name:' "$NODES_YAML_SRC" | sed 's/.*name: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d '[:space:]')
    [ -n "$NODE_NAME" ] || err "Could not extract node name from ${NODES_YAML_SRC}"
    info "Node name from config: ${NODE_NAME}"

    if [ -f "$STATE_FILE" ]; then
        local existing_vpc
        existing_vpc=$(load_state "vpc_id")
        if [ -n "$existing_vpc" ]; then
            err "Active deployment found (VPC: ${existing_vpc}). Run 'teardown' first or delete ${STATE_FILE}."
        fi
    fi

    # Build Linux amd64 binaries if missing
    local need_build=false
    for bin in testnet-server testnet-client testnet-node testnet-toolkit; do
        [ -f "${DIST_DIR}/${bin}-linux-amd64" ] || need_build=true
    done
    if $need_build; then
        command -v go >/dev/null 2>&1 || err "Go not found and binaries not pre-built. Install Go 1.25+ or run: make release"
        info "Cross-compiling Linux amd64 binaries..."
        mkdir -p "$DIST_DIR"
        for bin in testnet-server testnet-client testnet-node testnet-toolkit; do
            CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
                go build -ldflags="-s -w" -o "${DIST_DIR}/${bin}-linux-amd64" "${PROJECT_DIR}/cmd/${bin}"
            info "  Built ${bin}-linux-amd64"
        done
    else
        info "Using existing binaries in dist/"
    fi

    # Find Ubuntu 24.04 AMI
    info "Finding Ubuntu 24.04 AMI in ${REGION}..."
    AMI_ID=$(aws ec2 describe-images \
        --region "$REGION" \
        --owners 099720109477 \
        --filters \
            "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
            "Name=state,Values=available" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text)
    [ "$AMI_ID" != "None" ] && [ -n "$AMI_ID" ] || err "Could not find Ubuntu 24.04 AMI"
    info "Using AMI: ${AMI_ID}"
    save_state "ami_id" "$AMI_ID"

    # Create VPC
    info "Creating VPC..."
    VPC_ID=$(aws ec2 create-vpc \
        --region "$REGION" \
        --cidr-block "10.0.0.0/16" \
        --tag-specifications "$(tag_spec vpc vpc)" \
        --query 'Vpc.VpcId' --output text)
    save_state "vpc_id" "$VPC_ID"
    info "VPC: ${VPC_ID}"

    aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
    aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'

    # Create Internet Gateway
    info "Creating Internet Gateway..."
    IGW_ID=$(aws ec2 create-internet-gateway \
        --region "$REGION" \
        --tag-specifications "$(tag_spec internet-gateway igw)" \
        --query 'InternetGateway.InternetGatewayId' --output text)
    save_state "igw_id" "$IGW_ID"
    aws ec2 attach-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"

    # Create public subnet
    info "Creating subnet..."
    AZ=$(aws ec2 describe-availability-zones \
        --region "$REGION" \
        --query 'AvailabilityZones[0].ZoneName' --output text)
    SUBNET_ID=$(aws ec2 create-subnet \
        --region "$REGION" \
        --vpc-id "$VPC_ID" \
        --cidr-block "10.0.1.0/24" \
        --availability-zone "$AZ" \
        --tag-specifications "$(tag_spec subnet public)" \
        --query 'Subnet.SubnetId' --output text)
    save_state "subnet_id" "$SUBNET_ID"
    aws ec2 modify-subnet-attribute --region "$REGION" --subnet-id "$SUBNET_ID" --map-public-ip-on-launch

    # Route table
    info "Configuring route table..."
    RTB_ID=$(aws ec2 create-route-table \
        --region "$REGION" \
        --vpc-id "$VPC_ID" \
        --tag-specifications "$(tag_spec route-table public)" \
        --query 'RouteTable.RouteTableId' --output text)
    save_state "rtb_id" "$RTB_ID"
    aws ec2 create-route --region "$REGION" --route-table-id "$RTB_ID" \
        --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" >/dev/null
    aws ec2 associate-route-table --region "$REGION" --route-table-id "$RTB_ID" --subnet-id "$SUBNET_ID" >/dev/null

    # Security group: server
    info "Creating security groups..."
    SG_SERVER=$(aws ec2 create-security-group \
        --region "$REGION" \
        --group-name "testnet-server-sg" \
        --description "Testnet server: API + WireGuard + DNS" \
        --vpc-id "$VPC_ID" \
        --tag-specifications "$(tag_spec security-group server-sg)" \
        --query 'GroupId' --output text)
    save_state "sg_server" "$SG_SERVER"

    for rule in \
        "tcp 22 22 0.0.0.0/0" \
        "tcp 8443 8443 0.0.0.0/0" \
        "udp 51820 51820 0.0.0.0/0" \
        "udp 5353 5353 0.0.0.0/0" \
        "tcp 5353 5353 0.0.0.0/0"; do
        read -r proto from to cidr <<< "$rule"
        aws ec2 authorize-security-group-ingress --region "$REGION" \
            --group-id "$SG_SERVER" --protocol "$proto" \
            --port "${from}-${to}" --cidr "$cidr" >/dev/null
    done

    # Security group: node
    SG_NODE=$(aws ec2 create-security-group \
        --region "$REGION" \
        --group-name "testnet-node-sg" \
        --description "Testnet node: HTTPS" \
        --vpc-id "$VPC_ID" \
        --tag-specifications "$(tag_spec security-group node-sg)" \
        --query 'GroupId' --output text)
    save_state "sg_node" "$SG_NODE"

    for rule in \
        "tcp 22 22 0.0.0.0/0" \
        "tcp 443 443 0.0.0.0/0"; do
        read -r proto from to cidr <<< "$rule"
        aws ec2 authorize-security-group-ingress --region "$REGION" \
            --group-id "$SG_NODE" --protocol "$proto" \
            --port "${from}-${to}" --cidr "$cidr" >/dev/null
    done

    # Security group: client
    SG_CLIENT=$(aws ec2 create-security-group \
        --region "$REGION" \
        --group-name "testnet-client-sg" \
        --description "Testnet client: SSH only" \
        --vpc-id "$VPC_ID" \
        --tag-specifications "$(tag_spec security-group client-sg)" \
        --query 'GroupId' --output text)
    save_state "sg_client" "$SG_CLIENT"

    aws ec2 authorize-security-group-ingress --region "$REGION" \
        --group-id "$SG_CLIENT" --protocol tcp \
        --port "22-22" --cidr "0.0.0.0/0" >/dev/null

    # SSH key pair
    KEY_FILE="${SCRIPT_DIR}/.aws-testnet-key.pem"
    if [ ! -f "$KEY_FILE" ]; then
        info "Creating SSH key pair..."
        aws ec2 delete-key-pair --region "$REGION" --key-name "testnet-deploy-key" >/dev/null 2>&1 || true
        aws ec2 create-key-pair \
            --region "$REGION" \
            --key-name "testnet-deploy-key" \
            --key-type ed25519 \
            --tag-specifications "$(tag_spec key-pair deploy-key)" \
            --query 'KeyMaterial' --output text > "$KEY_FILE"
        chmod 600 "$KEY_FILE"
    else
        info "Using existing SSH key: ${KEY_FILE}"
        aws ec2 describe-key-pairs --region "$REGION" --key-names "testnet-deploy-key" >/dev/null 2>&1 || \
            err "Key file exists but key pair not in AWS. Delete ${KEY_FILE} and re-run."
    fi
    save_state "key_name" "testnet-deploy-key"
    save_state "key_file" "$KEY_FILE"

    # Launch instances
    # Args: role sg instance_type [cpu_options]
    launch_instance() {
        local role="$1" sg="$2" itype="$3" cpu_opts="${4:-}"
        info "Launching ${role} instance (${itype})..." >&2
        local cpu_flag=()
        if [ -n "$cpu_opts" ]; then
            cpu_flag=(--cpu-options "$cpu_opts")
        fi
        local instance_id
        instance_id=$(aws ec2 run-instances \
            --region "$REGION" \
            --image-id "$AMI_ID" \
            --instance-type "$itype" \
            --key-name "testnet-deploy-key" \
            --subnet-id "$SUBNET_ID" \
            --security-group-ids "$sg" \
            --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":20,"VolumeType":"gp3"}}]' \
            --tag-specifications "$(tag_spec instance "$role")" \
            "${cpu_flag[@]}" \
            --query 'Instances[0].InstanceId' --output text)
        save_state "instance_${role}" "$instance_id"
        echo "$instance_id"
    }

    INST_SERVER=$(launch_instance "server" "$SG_SERVER" "$INSTANCE_TYPE_SERVER")
    INST_NODE=$(launch_instance "node" "$SG_NODE" "$INSTANCE_TYPE_NODE")
    INST_CLIENT=$(launch_instance "client" "$SG_CLIENT" "$INSTANCE_TYPE_CLIENT" "NestedVirtualization=enabled")

    info "Waiting for instances to be running..."
    aws ec2 wait instance-running --region "$REGION" --instance-ids "$INST_SERVER" "$INST_NODE" "$INST_CLIENT"

    # Get public IPs
    get_ip() {
        aws ec2 describe-instances --region "$REGION" --instance-ids "$1" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
    }

    IP_SERVER=$(get_ip "$INST_SERVER")
    IP_NODE=$(get_ip "$INST_NODE")
    IP_CLIENT=$(get_ip "$INST_CLIENT")
    save_state "ip_server" "$IP_SERVER"
    save_state "ip_node" "$IP_NODE"
    save_state "ip_client" "$IP_CLIENT"

    info "Instance IPs:"
    echo "  Server:  ${IP_SERVER}"
    echo "  Node:    ${IP_NODE}"
    echo "  Client:  ${IP_CLIENT}"

    # Wait for SSH on all instances
    wait_for_ssh "$IP_SERVER" "$KEY_FILE"
    wait_for_ssh "$IP_NODE" "$KEY_FILE"
    wait_for_ssh "$IP_CLIENT" "$KEY_FILE"

    # ---- Deploy server ----
    info "Deploying server..."
    remote_copy "$KEY_FILE" "${DIST_DIR}/testnet-server-linux-amd64" "ubuntu@${IP_SERVER}:/tmp/testnet-server"
    remote_copy "$KEY_FILE" "${SCRIPT_DIR}/install.sh" "ubuntu@${IP_SERVER}:/tmp/install.sh"

    # Patch nodes.yaml: replace placeholder address and secret with deploy-time values
    [ -f "$NODES_YAML_SRC" ] || err "Missing ${NODES_YAML_SRC}"
    local nodes_tmp="${SCRIPT_DIR}/.nodes-deploy.yaml"
    sed -e "s|DEPLOY_NODE_ADDRESS|${IP_NODE}:443|g" \
        -e "s|DEPLOY_NODE_SECRET|${NODE_SECRET}|g" \
        "$NODES_YAML_SRC" > "$nodes_tmp"
    remote_copy "$KEY_FILE" "$nodes_tmp" "ubuntu@${IP_SERVER}:/tmp/nodes.yaml"
    rm -f "$nodes_tmp"

    remote_exec "$IP_SERVER" "$KEY_FILE" "
        sudo mkdir -p /usr/local/bin
        sudo mv /tmp/testnet-server /usr/local/bin/testnet-server
        sudo chmod +x /usr/local/bin/testnet-server
        export AUTO_START=1
        sudo -E bash /tmp/install.sh server
    "

    # Get join token from server (retry up to 30s for the server to generate it)
    info "Retrieving join token from server..."
    JOIN_TOKEN=""
    for _ in $(seq 1 10); do
        JOIN_TOKEN=$(remote_exec "$IP_SERVER" "$KEY_FILE" "sudo cat /opt/testnet/data/join-token 2>/dev/null" || echo "")
        [ -n "$JOIN_TOKEN" ] && break
        sleep 3
    done
    if [ -z "$JOIN_TOKEN" ]; then
        err "Could not retrieve join token after 30s. Check: ssh -i ${KEY_FILE} ubuntu@${IP_SERVER} 'sudo journalctl -u testnet-server -f'"
    fi
    info "Join token: ${JOIN_TOKEN}"
    save_state "join_token" "$JOIN_TOKEN"

    # ---- Deploy node ----
    info "Deploying node..."
    remote_copy "$KEY_FILE" "${DIST_DIR}/testnet-node-linux-amd64" "ubuntu@${IP_NODE}:/tmp/testnet-node"
    remote_copy "$KEY_FILE" "${DIST_DIR}/testnet-toolkit-linux-amd64" "ubuntu@${IP_NODE}:/tmp/testnet-toolkit"
    remote_copy "$KEY_FILE" "${SCRIPT_DIR}/install.sh" "ubuntu@${IP_NODE}:/tmp/install.sh"

    remote_exec "$IP_NODE" "$KEY_FILE" "
        sudo mkdir -p /usr/local/bin
        sudo mv /tmp/testnet-node /usr/local/bin/testnet-node
        sudo chmod +x /usr/local/bin/testnet-node
        sudo mv /tmp/testnet-toolkit /usr/local/bin/testnet-toolkit
        sudo chmod +x /usr/local/bin/testnet-toolkit
        export SERVER_URL='https://${IP_SERVER}:8443'
        export NODE_NAME='${NODE_NAME}'
        export NODE_SECRET='${NODE_SECRET}'
        sudo -E bash /tmp/install.sh node
    "

    # ---- Deploy client ----
    info "Deploying client..."
    remote_copy "$KEY_FILE" "${DIST_DIR}/testnet-client-linux-amd64" "ubuntu@${IP_CLIENT}:/tmp/testnet-client"
    remote_copy "$KEY_FILE" "${SCRIPT_DIR}/install.sh" "ubuntu@${IP_CLIENT}:/tmp/install.sh"

    remote_exec "$IP_CLIENT" "$KEY_FILE" "
        sudo mkdir -p /usr/local/bin
        sudo mv /tmp/testnet-client /usr/local/bin/testnet-client
        sudo chmod +x /usr/local/bin/testnet-client
        export SERVER_URL='https://${IP_SERVER}:8443'
        export JOIN_TOKEN='${JOIN_TOKEN}'
        sudo -E bash /tmp/install.sh client
    "

    # Save node secret
    save_state "node_name" "$NODE_NAME"
    save_state "node_secret" "$NODE_SECRET"

    # ---- Verify services ----
    info "Verifying services..."
    local all_healthy=true

    # Server: systemd active + API port listening
    if remote_exec "$IP_SERVER" "$KEY_FILE" "sudo systemctl is-active --quiet testnet-server" 2>/dev/null; then
        info "  Server: healthy"
    else
        warn "  Server: testnet-server service not active"
        all_healthy=false
    fi

    # Node: systemd active
    if remote_exec "$IP_NODE" "$KEY_FILE" "sudo systemctl is-active --quiet testnet-node" 2>/dev/null; then
        info "  Node: healthy"
    else
        warn "  Node: testnet-node service not active"
        all_healthy=false
    fi

    # Client: WireGuard tunnel up + handshake completed
    local wg_status
    wg_status=$(remote_exec "$IP_CLIENT" "$KEY_FILE" "sudo wg show wg-testnet 2>/dev/null | grep 'latest handshake'" 2>/dev/null || echo "")
    if [ -n "$wg_status" ]; then
        info "  Client: healthy (WireGuard tunnel established)"
    else
        warn "  Client: WireGuard tunnel not established yet"
        all_healthy=false
    fi

    # Client: /dev/kvm available (for Firecracker)
    if remote_exec "$IP_CLIENT" "$KEY_FILE" "test -e /dev/kvm" 2>/dev/null; then
        info "  Client: /dev/kvm available (Firecracker ready)"
    else
        warn "  Client: /dev/kvm not found (Firecracker VMs will not work)"
    fi

    if $all_healthy; then
        info "All services healthy!"
    else
        warn "Some services are unhealthy. Check logs with: bash deploy/aws-deploy.sh ssh <role>"
    fi

    # ---- Summary ----
    echo ""
    echo "============================================"
    echo "  Agent Testnet deployed on AWS"
    echo "============================================"
    echo ""
    echo "  Region:  ${REGION}"
    echo "  VPC:     ${VPC_ID}"
    echo ""
    echo "  Server:  ${IP_SERVER}  (${INST_SERVER})"
    echo "  Node:    ${IP_NODE}  (${INST_NODE})"
    echo "  Client:  ${IP_CLIENT}  (${INST_CLIENT})"
    echo ""
    echo "  SSH key:    ${KEY_FILE}"
    echo "  Node name:  ${NODE_NAME}"
    echo "  Node secret: ${NODE_SECRET}"
    echo "  Join token: ${JOIN_TOKEN}"
    echo ""
    echo "  SSH commands:"
    echo "    ssh -i ${KEY_FILE} ubuntu@${IP_SERVER}   # server"
    echo "    ssh -i ${KEY_FILE} ubuntu@${IP_NODE}     # node"
    echo "    ssh -i ${KEY_FILE} ubuntu@${IP_CLIENT}   # client"
    echo ""
    echo "  Check logs:"
    echo "    ssh -i ${KEY_FILE} ubuntu@${IP_SERVER} 'sudo journalctl -u testnet-server -f'"
    echo "    ssh -i ${KEY_FILE} ubuntu@${IP_NODE}   'sudo journalctl -u testnet-node -f'"
    echo "    ssh -i ${KEY_FILE} ubuntu@${IP_CLIENT} 'sudo journalctl -u testnet-client -f'"
    echo ""
    echo "  Teardown:"
    echo "    bash deploy/aws-deploy.sh teardown"
    echo ""
    echo "  Instance types: server=${INSTANCE_TYPE_SERVER}, node=${INSTANCE_TYPE_NODE}, client=${INSTANCE_TYPE_CLIENT}"
    echo "  Override with: INSTANCE_TYPE_CLIENT=<type> bash deploy/aws-deploy.sh deploy"
    echo ""
}

# ---- status ----

do_status() {
    if [ ! -f "$STATE_FILE" ]; then
        err "No state file found. Run 'deploy' first."
    fi

    local inst_server inst_node inst_client
    inst_server=$(load_state "instance_server")
    inst_node=$(load_state "instance_node")
    inst_client=$(load_state "instance_client")

    if [ -z "$inst_server" ]; then
        err "No instances found in state file."
    fi

    local key_file ip_server
    key_file=$(load_state "key_file")
    ip_server=$(load_state "ip_server")

    echo ""
    echo "Agent Testnet Status (${REGION})"
    echo "================================"
    echo ""

    # -- EC2 instances --
    echo "Instances:"
    printf "  %-8s  %-20s  %-16s  %-10s  %s\n" "ROLE" "INSTANCE" "IP" "EC2" "SERVICE"
    printf "  %-8s  %-20s  %-16s  %-10s  %s\n" "--------" "--------------------" "----------------" "----------" "-------"
    for role in server node client; do
        local inst_id ip ec2_state svc_state svc_name
        inst_id=$(load_state "instance_${role}")
        ip=$(load_state "ip_${role}")
        if [ -z "$inst_id" ]; then continue; fi

        ec2_state=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$inst_id" \
            --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "unknown")

        svc_name="testnet-${role}"
        if [ "$ec2_state" = "running" ] && [ -f "$key_file" ]; then
            svc_state=$(remote_exec "$ip" "$key_file" \
                "systemctl is-active $svc_name 2>/dev/null || echo 'inactive'" 2>/dev/null) || svc_state="ssh-err"
        else
            svc_state="-"
        fi
        printf "  %-8s  %-20s  %-16s  %-10s  %s\n" "$role" "$inst_id" "$ip" "$ec2_state" "$svc_state"
    done

    # -- Registered nodes & domains (from server) --
    if [ -n "$ip_server" ] && [ -f "$key_file" ]; then
        local nodes_yaml
        nodes_yaml=$(remote_exec "$ip_server" "$key_file" \
            "sudo cat /opt/testnet/configs/nodes.yaml 2>/dev/null" 2>/dev/null) || true

        if [ -n "$nodes_yaml" ]; then
            echo ""
            echo "Registered nodes (from server nodes.yaml):"
            printf "  %-12s  %-24s  %s\n" "NAME" "ADDRESS" "DOMAINS"
            printf "  %-12s  %-24s  %s\n" "------------" "------------------------" "-------"
            echo "$nodes_yaml" | awk '
                /- name:/    { if (name) printf "  %-12s  %-24s  %s\n", name, addr, domains;
                               gsub(/.*name: *"?/, ""); gsub(/".*/, ""); name=$0; addr=""; domains="" }
                /address:/   { gsub(/.*address: *"?/, ""); gsub(/".*/, ""); addr=$0 }
                /^ *- "/ || /^ *- '\''/ { gsub(/.*- *"?/, ""); gsub(/".*/, ""); gsub(/'\''.*/, "");
                               if (domains) domains = domains ", " $0; else domains=$0 }
                END          { if (name) printf "  %-12s  %-24s  %s\n", name, addr, domains }
            '
        fi

        # -- WireGuard peers (connected clients) --
        echo ""
        echo "WireGuard peers:"
        remote_exec "$ip_server" "$key_file" \
            "sudo wg show wg0 2>/dev/null | grep -E '(peer|endpoint|latest handshake|transfer)' | sed 's/^/  /'" 2>/dev/null || echo "  (no tunnel or wg not running)"

        # -- Recent server log --
        echo ""
        echo "Server log (last 5 lines):"
        remote_exec "$ip_server" "$key_file" \
            "sudo journalctl -u testnet-server --no-pager -n 5 --output short-iso 2>/dev/null | sed 's/^/  /'" 2>/dev/null || echo "  (unavailable)"
    fi

    local join_token
    join_token=$(load_state "join_token")
    if [ -n "$join_token" ]; then
        echo ""
        echo "Join token: ${join_token}"
    fi

    echo ""
    echo "SSH: ssh -i ${key_file} ubuntu@<IP>"
    echo ""
}

# ---- ssh ----

do_ssh() {
    local role="${1:-}"
    [ -n "$role" ] || err "Usage: $0 ssh <server|node|client>"
    [ -f "$STATE_FILE" ] || err "No state file. Run 'deploy' first."

    local ip key_file
    ip=$(load_state "ip_${role}")
    key_file=$(load_state "key_file")

    [ -n "$ip" ] || err "No IP found for role: ${role}"
    [ -f "$key_file" ] || err "SSH key not found: ${key_file}"

    exec ssh -o StrictHostKeyChecking=no -i "$key_file" "ubuntu@${ip}"
}

# ---- reload ----

do_reload() {
    [ -f "$STATE_FILE" ] || err "No state file. Run 'deploy' first."
    if [ ! -f "$NODES_YAML_SRC" ]; then
        err "Missing ${NODES_YAML_SRC}. Copy the example and edit it:
  cp configs/nodes.yaml.example configs/nodes.yaml"
    fi

    local ip_server ip_node key_file node_secret
    ip_server=$(load_state "ip_server")
    ip_node=$(load_state "ip_node")
    key_file=$(load_state "key_file")
    node_secret=$(load_state "node_secret")
    [ -n "$ip_server" ] || err "No server IP in state file."
    [ -n "$ip_node" ] || err "No node IP in state file."
    [ -f "$key_file" ] || err "SSH key not found: ${key_file}"
    [ -n "$node_secret" ] || err "No node secret in state file."

    local nodes_tmp="${SCRIPT_DIR}/.nodes-deploy.yaml"
    sed -e "s|DEPLOY_NODE_ADDRESS|${ip_node}:443|g" \
        -e "s|DEPLOY_NODE_SECRET|${node_secret}|g" \
        "$NODES_YAML_SRC" > "$nodes_tmp"

    info "Uploading updated nodes.yaml to server (${ip_server})..."
    remote_copy "$key_file" "$nodes_tmp" "ubuntu@${ip_server}:/tmp/nodes.yaml"
    rm -f "$nodes_tmp"

    # Invalidate the CA's cached certs so new certs are issued with updated SANs.
    # The certs dir is root-owned (0700), so the glob must run inside sudo bash.
    remote_exec "$ip_server" "$key_file" "
        sudo cp /tmp/nodes.yaml /opt/testnet/configs/nodes.yaml
        sudo bash -c 'rm -rf /opt/testnet/data/certs/*'
        sudo systemctl reload testnet-server
    "
    info "Server reloaded (cert cache cleared)."
    info "If domain assignments changed, restart affected nodes: bash deploy/aws-deploy.sh restart node"
}

# ---- restart ----

do_restart() {
    local role="${1:-}"
    [ -n "$role" ] || err "Usage: $0 restart <server|node|client>"
    [ -f "$STATE_FILE" ] || err "No state file. Run 'deploy' first."

    local ip key_file service_name
    ip=$(load_state "ip_${role}")
    key_file=$(load_state "key_file")
    [ -n "$ip" ] || err "No IP found for role: ${role}"
    [ -f "$key_file" ] || err "SSH key not found: ${key_file}"

    case "$role" in
        server) service_name="testnet-server" ;;
        node)   service_name="testnet-node" ;;
        client) service_name="testnet-client" ;;
        *)      err "Unknown role: ${role}. Use: server, node, client" ;;
    esac

    # For node restarts, also sync the node name from config
    if [ "$role" = "node" ] && [ -f "$NODES_YAML_SRC" ]; then
        local NODE_NAME
        NODE_NAME=$(grep -m1 'name:' "$NODES_YAML_SRC" | sed 's/.*name: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d '[:space:]')
        if [ -n "$NODE_NAME" ]; then
            info "Syncing node name to '${NODE_NAME}'..."
            remote_exec "$ip" "$key_file" "
                sudo sed -i \"s/^NODE_NAME=.*/NODE_NAME=${NODE_NAME}/\" /etc/testnet/node.env
            "
        fi
    fi

    info "Restarting ${service_name} on ${ip}..."
    remote_exec "$ip" "$key_file" "sudo systemctl restart ${service_name}"
    sleep 3
    if remote_exec "$ip" "$key_file" "sudo systemctl is-active --quiet ${service_name}" 2>/dev/null; then
        info "${service_name} is running."
    else
        warn "${service_name} may not have started cleanly. Check: ssh -i ${key_file} ubuntu@${ip} 'sudo journalctl -u ${service_name} -f'"
    fi
}

# ---- redeploy ----

do_redeploy() {
    local role="${1:-}"
    [ -n "$role" ] || err "Usage: $0 redeploy <server|node|client>"
    [ -f "$STATE_FILE" ] || err "No state file. Run 'deploy' first."

    local ip key_file
    ip=$(load_state "ip_${role}")
    key_file=$(load_state "key_file")
    [ -n "$ip" ] || err "No IP found for role: ${role}"
    [ -f "$key_file" ] || err "SSH key not found: ${key_file}"

    local bin_name
    case "$role" in
        server) bin_name="testnet-server" ;;
        node)   bin_name="testnet-node" ;;
        client) bin_name="testnet-client" ;;
        *)      err "Unknown role: ${role}. Use: server, node, client" ;;
    esac

    local bin_path="${DIST_DIR}/${bin_name}-linux-amd64"

    command -v go >/dev/null 2>&1 || err "Go not found. Install Go 1.25+ or pre-build: make release"
    info "Building ${bin_name} for linux/amd64..."
    mkdir -p "$DIST_DIR"
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
        go build -ldflags="-s -w" -o "$bin_path" "${PROJECT_DIR}/cmd/${bin_name}"

    info "Uploading ${bin_name} to ${role} (${ip})..."
    remote_copy "$key_file" "$bin_path" "ubuntu@${ip}:/tmp/${bin_name}"
    remote_exec "$ip" "$key_file" "
        sudo mv /tmp/${bin_name} /usr/local/bin/${bin_name}
        sudo chmod +x /usr/local/bin/${bin_name}
    "

    # Also upload toolkit when redeploying the node (matches initial deploy)
    if [ "$role" = "node" ]; then
        local toolkit_path="${DIST_DIR}/testnet-toolkit-linux-amd64"
        if [ -f "$toolkit_path" ]; then
            info "Uploading testnet-toolkit to node..."
            remote_copy "$key_file" "$toolkit_path" "ubuntu@${ip}:/tmp/testnet-toolkit"
            remote_exec "$ip" "$key_file" "
                sudo mv /tmp/testnet-toolkit /usr/local/bin/testnet-toolkit
                sudo chmod +x /usr/local/bin/testnet-toolkit
            "
        fi
    fi

    info "Restarting ${bin_name}..."
    do_restart "$role"
}

# ---- test ----

do_test() {
    [ -f "$STATE_FILE" ] || err "No state file. Run 'deploy' first."

    local ip_client key_file
    ip_client=$(load_state "ip_client")
    key_file=$(load_state "key_file")
    [ -n "$ip_client" ] || err "No client IP in state file."
    [ -f "$key_file" ] || err "SSH key not found: ${key_file}"

    local test_script="${PROJECT_DIR}/scripts/vm-integration-test.sh"
    [ -f "$test_script" ] || err "Test script not found: ${test_script}"
    if [ ! -f "$NODES_YAML_SRC" ]; then
        err "Missing ${NODES_YAML_SRC}. Copy the example and edit it:
  cp configs/nodes.yaml.example configs/nodes.yaml"
    fi

    info "Uploading integration test to client (${ip_client})..."
    remote_copy "$key_file" "$test_script" "ubuntu@${ip_client}:/tmp/vm-integration-test.sh"
    remote_copy "$key_file" "$NODES_YAML_SRC" "ubuntu@${ip_client}:/tmp/nodes.yaml"

    info "Running integration test (this launches a Firecracker VM)..."
    remote_exec "$ip_client" "$key_file" "sudo bash /tmp/vm-integration-test.sh /tmp/nodes.yaml"
}

# ---- teardown ----

do_teardown() {
    if [ ! -f "$STATE_FILE" ]; then
        err "No state file found. Nothing to tear down."
    fi

    info "Tearing down Agent Testnet in ${REGION}..."

    # Terminate instances
    for role in server node client; do
        local inst_id
        inst_id=$(load_state "instance_${role}")
        if [ -n "$inst_id" ]; then
            info "Terminating ${role} instance: ${inst_id}..."
            aws ec2 terminate-instances --region "$REGION" --instance-ids "$inst_id" >/dev/null 2>&1 || true
        fi
    done

    # Wait for termination
    local all_instances=""
    for role in server node client; do
        local inst_id
        inst_id=$(load_state "instance_${role}")
        [ -n "$inst_id" ] && all_instances="${all_instances} ${inst_id}"
    done
    if [ -n "$all_instances" ]; then
        info "Waiting for instances to terminate..."
        aws ec2 wait instance-terminated --region "$REGION" --instance-ids $all_instances 2>/dev/null || true
    fi

    # Delete key pair
    local key_name
    key_name=$(load_state "key_name")
    if [ -n "$key_name" ]; then
        info "Deleting key pair: ${key_name}..."
        aws ec2 delete-key-pair --region "$REGION" --key-name "$key_name" 2>/dev/null || true
    fi

    # Delete security groups
    for sg_key in sg_server sg_node sg_client; do
        local sg_id
        sg_id=$(load_state "$sg_key")
        if [ -n "$sg_id" ]; then
            info "Deleting security group: ${sg_id}..."
            aws ec2 delete-security-group --region "$REGION" --group-id "$sg_id" 2>/dev/null || true
        fi
    done

    # Delete subnet
    local subnet_id
    subnet_id=$(load_state "subnet_id")
    if [ -n "$subnet_id" ]; then
        info "Deleting subnet: ${subnet_id}..."
        aws ec2 delete-subnet --region "$REGION" --subnet-id "$subnet_id" 2>/dev/null || true
    fi

    # Delete route table
    local rtb_id
    rtb_id=$(load_state "rtb_id")
    if [ -n "$rtb_id" ]; then
        info "Deleting route table: ${rtb_id}..."
        aws ec2 delete-route-table --region "$REGION" --route-table-id "$rtb_id" 2>/dev/null || true
    fi

    # Detach and delete internet gateway
    local igw_id vpc_id
    igw_id=$(load_state "igw_id")
    vpc_id=$(load_state "vpc_id")
    if [ -n "$igw_id" ] && [ -n "$vpc_id" ]; then
        info "Detaching internet gateway: ${igw_id}..."
        aws ec2 detach-internet-gateway --region "$REGION" --internet-gateway-id "$igw_id" --vpc-id "$vpc_id" 2>/dev/null || true
    fi
    if [ -n "$igw_id" ]; then
        info "Deleting internet gateway: ${igw_id}..."
        aws ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$igw_id" 2>/dev/null || true
    fi

    # Delete VPC
    if [ -n "$vpc_id" ]; then
        info "Deleting VPC: ${vpc_id}..."
        aws ec2 delete-vpc --region "$REGION" --vpc-id "$vpc_id" 2>/dev/null || true
    fi

    # Clean up local state
    local key_file
    key_file=$(load_state "key_file")
    if [ -n "$key_file" ] && [ -f "$key_file" ]; then
        rm -f "$key_file"
        info "Removed SSH key: ${key_file}"
    fi
    rm -f "$STATE_FILE"

    info "Teardown complete."
}

# ---- openclaw ----

do_openclaw() {
    local subcmd="${1:-install}"
    shift || true

    [ -f "$STATE_FILE" ] || err "No state file. Run 'deploy' first."

    local ip_client key_file
    ip_client=$(load_state "ip_client")
    key_file=$(load_state "key_file")
    [ -n "$ip_client" ] || err "No client IP in state file."
    [ -f "$key_file" ] || err "SSH key not found: ${key_file}"

    local oc_script="${PROJECT_DIR}/scripts/install-openclaw.sh"
    [ -f "$oc_script" ] || err "Missing ${oc_script}"

    # Upload the script (idempotent)
    remote_copy "$key_file" "$oc_script" "ubuntu@${ip_client}:/tmp/install-openclaw.sh"

    # Shared arg parser for install and reconfig
    parse_openclaw_args() {
        OC_API_KEY="${OPENCLAW_API_KEY:-${ANTHROPIC_API_KEY:-${OPENAI_API_KEY:-${OPENROUTER_API_KEY:-}}}}"
        OC_PROVIDER=""
        OC_MODEL=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --api-key)  OC_API_KEY="$2"; shift 2 ;;
                --provider) OC_PROVIDER="$2"; shift 2 ;;
                --model)    OC_MODEL="$2"; shift 2 ;;
                *)          err "Unknown openclaw option: $1" ;;
            esac
        done
    }

    case "$subcmd" in
        install)
            parse_openclaw_args "$@"
            [ -n "${OC_PROVIDER}" ] || OC_PROVIDER="anthropic"

            [ -n "$OC_API_KEY" ] || err "API key required. Pass --api-key KEY or export OPENCLAW_API_KEY."

            local extra_args="--provider ${OC_PROVIDER}"
            [ -n "$OC_MODEL" ] && extra_args="${extra_args} --model ${OC_MODEL}"

            info "Installing OpenClaw on client VM (${ip_client})..."
            info "This will launch a Firecracker agent VM, install Node.js + OpenClaw,"
            info "set up LLM API proxies, and start the gateway. This takes a few minutes."
            echo ""

            remote_exec "$ip_client" "$key_file" \
                "OPENCLAW_API_KEY='${OC_API_KEY}' DEPLOY_MODE=1 sudo -E bash /tmp/install-openclaw.sh install ${extra_args}"
            ;;

        reconfig)
            parse_openclaw_args "$@"

            [ -n "$OC_API_KEY" ] || err "API key required. Pass --api-key KEY or export OPENCLAW_API_KEY / OPENROUTER_API_KEY."

            local extra_args=""
            [ -n "$OC_PROVIDER" ] && extra_args="--provider ${OC_PROVIDER}"
            [ -n "$OC_MODEL" ] && extra_args="${extra_args} --model ${OC_MODEL}"

            info "Reconfiguring OpenClaw on client VM (${ip_client})..."
            remote_exec "$ip_client" "$key_file" \
                "OPENCLAW_API_KEY='${OC_API_KEY}' sudo -E bash /tmp/install-openclaw.sh reconfig ${extra_args}"
            ;;

        chat)
            info "Connecting to OpenClaw on client VM (${ip_client})..."
            info "Press Ctrl+C to exit."
            echo ""

            # Interactive: needs -t for TTY pass-through across both SSH hops
            # (local -> EC2 client -> install-openclaw.sh chat -> Firecracker VM)
            exec ssh -o StrictHostKeyChecking=no -t -i "$key_file" "ubuntu@${ip_client}" \
                "sudo bash /tmp/install-openclaw.sh chat"
            ;;

        status)
            remote_exec "$ip_client" "$key_file" \
                "sudo bash /tmp/install-openclaw.sh status"
            ;;

        stop)
            info "Stopping OpenClaw on client VM (${ip_client})..."
            remote_exec "$ip_client" "$key_file" \
                "sudo bash /tmp/install-openclaw.sh stop"
            ;;

        *)
            err "Unknown openclaw subcommand: ${subcmd}. Use: install, reconfig, chat, status, stop"
            ;;
    esac
}

# ---- main ----

ACTION="${1:-}"
case "$ACTION" in
    deploy)   do_deploy ;;
    teardown) do_teardown ;;
    status)   do_status ;;
    ssh)      do_ssh "${2:-}" ;;
    restart)  do_restart "${2:-}" ;;
    redeploy) do_redeploy "${2:-}" ;;
    reload)   do_reload ;;
    test)     do_test ;;
    openclaw) shift; do_openclaw "$@" ;;
    "")       err "Usage: $0 <deploy|teardown|status|ssh|restart|redeploy|reload|test|openclaw>" ;;
    *)        err "Unknown action: $ACTION. Use: deploy, teardown, status, ssh, restart, redeploy, reload, test, openclaw" ;;
esac
