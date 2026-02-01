#!/bin/bash
set -e

cd "$(dirname "$0")"

CONFIG_FILE="config.yml"

# =============================================================================
# Config file parser
# =============================================================================
get_config() {
    local key="$1"
    local default="$2"
    if [[ -f "$CONFIG_FILE" ]]; then
        local value
        value=$(grep -E "^\s*${key##*.}:" "$CONFIG_FILE" | head -1 | sed 's/.*:\s*//' | sed 's/#.*//' | sed 's/"//g' | sed "s/'//g" | tr -d ' ')
        if [[ -n "$value" && "$value" != "\"\"" && "$value" != "''" ]]; then
            echo "$value"
            return
        fi
    fi
    echo "$default"
}

# =============================================================================
# Load from saved state or config.yml
# =============================================================================
CLUSTER_NAME=""
VM_ID_START=""

# Try saved state first (from deploy), then config.yml
if [[ -f .cluster-name ]]; then
    CLUSTER_NAME=$(cat .cluster-name)
fi
if [[ -f .vm-id-start ]]; then
    VM_ID_START=$(cat .vm-id-start)
fi

# Load Proxmox settings from config
PROXMOX_HOST=$(get_config "host" "192.168.40.10")
PROXMOX_USER=$(get_config "user" "root@pam")
PROXMOX_NODE=$(get_config "node" "pve")
PROXMOX_STORAGE=$(get_config "storage" "speedy-nvme-drive")
PROXMOX_BRIDGE=$(get_config "network_bridge" "vmbr0")

# =============================================================================
# Parse CLI arguments (override saved state)
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --vm-id-start)
            VM_ID_START="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--cluster NAME] [--vm-id-start N]"
            echo ""
            echo "Destroys the cluster. If no options given, reads from last deploy."
            echo ""
            echo "Options:"
            echo "  --cluster NAME     - Cluster name prefix (default from last deploy)"
            echo "  --vm-id-start N    - Starting VM ID (default from last deploy)"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# Use defaults from config.yml if not set
CLUSTER_NAME="${CLUSTER_NAME:-$(get_config "name" "k8s")}"
VM_ID_START="${VM_ID_START:-$(get_config "vm_id_start" "200")}"

echo "=== Destroying k8s cluster: $CLUSTER_NAME ==="

# =============================================================================
# Build Terraform variables
# =============================================================================
TF_VARS=""
TF_VARS="$TF_VARS -var=proxmox_host=$PROXMOX_HOST"
TF_VARS="$TF_VARS -var=proxmox_user=$PROXMOX_USER"
TF_VARS="$TF_VARS -var=proxmox_node=$PROXMOX_NODE"
TF_VARS="$TF_VARS -var=vm_storage=$PROXMOX_STORAGE"
TF_VARS="$TF_VARS -var=vm_network_bridge=$PROXMOX_BRIDGE"
TF_VARS="$TF_VARS -var=vm_name_prefix=$CLUSTER_NAME"
TF_VARS="$TF_VARS -var=vm_id_start=$VM_ID_START"

# =============================================================================
# Terraform destroy
# =============================================================================
cd terraform
terraform destroy -auto-approve $TF_VARS
cd ..

# =============================================================================
# Cleanup
# =============================================================================
echo "=== Cleaning up generated files ==="
rm -f kubeconfig dashboard-token.txt s3-credentials.txt argocd-credentials.txt keycloak-credentials.txt
rm -f ansible/inventory.ini
rm -f .k8s-distro .lb-implementation .cluster-name .vm-id-start

echo "=== Cluster destroyed ==="
