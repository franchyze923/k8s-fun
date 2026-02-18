#!/bin/bash
set -eo pipefail

cd "$(dirname "$0")"

CONFIG_FILE="config.yml"
MAX_RETRIES=3
RETRY_DELAY=10

# =============================================================================
# Config file parser (simple YAML reader)
# =============================================================================
get_config() {
    local key="$1"
    local default="$2"
    if [[ -f "$CONFIG_FILE" ]]; then
        # Handle nested keys like "proxmox.host" or "vm.memory"
        local value
        # Use [^:]* to match only up to the FIRST colon (preserves URLs with https://)
        value=$(grep -E "^\s*${key##*.}:" "$CONFIG_FILE" | head -1 | sed 's/^[^:]*:\s*//' | sed 's/#.*//' | sed 's/"//g' | sed "s/'//g" | xargs)
        if [[ -n "$value" && "$value" != "\"\"" && "$value" != "''" ]]; then
            echo "$value"
            return
        fi
    fi
    echo "$default"
}

# =============================================================================
# Load defaults from config.yml
# =============================================================================
CLUSTER_NAME=$(get_config "name" "k8s")
VM_ID_START=$(get_config "vm_id_start" "200")
VM_COUNT=$(get_config "node_count" "3")
K8S_DISTRO=$(get_config "distribution" "k3s")
K8S_VERSION=$(get_config "version" "")
VM_MEMORY=$(get_config "memory" "4096")
VM_CORES=$(get_config "cores" "2")
VM_DISK_SIZE=$(get_config "disk_size" "32")
LB_IMPLEMENTATION=$(get_config "loadbalancer" "cilium")
LB_IP_START=$(get_config "lb_ip_start" "192.168.40.200")
LB_IP_END=$(get_config "lb_ip_end" "192.168.40.220")
INSTALL_CEPH=$(get_config "ceph_enabled" "false")
CEPH_DISK_SIZE=$(get_config "ceph_disk_size" "20")
PROXMOX_HOST=$(get_config "host" "192.168.40.10")
PROXMOX_USER=$(get_config "user" "root@pam")
PROXMOX_NODE=$(get_config "node" "pve")
PROXMOX_STORAGE=$(get_config "storage" "speedy-nvme-drive")
PROXMOX_BRIDGE=$(get_config "network_bridge" "vmbr0")

# App toggles
APP_DASHBOARD=$(get_config "dashboard" "true")
APP_DEMO=$(get_config "demo_apps" "true")
APP_ARGOCD=$(get_config "argocd" "true")
APP_KEYCLOAK=$(get_config "keycloak" "true")

# ArgoCD configuration
ARGOCD_REPO_URL=$(get_config "repo_url" "https://github.com/franchyze923/app-of-apps-demo.git")
ARGOCD_PATH=$(get_config "path" ".")
ARGOCD_BRANCH=$(get_config "branch" "main")
ARGOCD_APP_NAME=$(get_config "app_name" "app-of-apps")

# Backup configuration
BACKUP_ENABLED=$(get_config "enabled" "false")
BACKUP_LOCAL_MOUNT=$(get_config "local_mount" "")
BACKUP_PATH=$(get_config "backup_path" "")
NFS_SERVER=$(get_config "nfs_server" "")
NFS_SHARE=$(get_config "nfs_share" "")

SKIP_IMAGE_DOWNLOAD=false

# =============================================================================
# Usage
# =============================================================================
usage() {
    echo "Usage: $0 [k3s|kubeadm] [cilium|metallb] [options]"
    echo ""
    echo "All settings can be configured in config.yml or overridden via CLI flags."
    echo ""
    echo "Kubernetes distribution:"
    echo "  k3s      - Lightweight Kubernetes (default)"
    echo "  kubeadm  - Standard Kubernetes with kubeadm"
    echo ""
    echo "LoadBalancer:"
    echo "  cilium   - Cilium L2 LoadBalancer (default)"
    echo "  metallb  - MetalLB LoadBalancer"
    echo ""
    echo "Options:"
    echo "  --ceph             - Install Rook-Ceph storage and S3"
    echo "  --memory MB        - RAM per VM in MB (default: $VM_MEMORY)"
    echo "  --cores N          - CPU cores per VM (default: $VM_CORES)"
    echo "  --disk-size GB     - OS disk size in GB (default: $VM_DISK_SIZE)"
    echo "  --cluster NAME     - Cluster name prefix (default: $CLUSTER_NAME)"
    echo "  --vm-id-start N    - Starting VM ID (default: $VM_ID_START)"
    echo "  --lb-range START-END - LoadBalancer IP range (default: $LB_IP_START-$LB_IP_END)"
    echo "  --skip-image-download - Skip cloud image download (use existing)"
    echo ""
    echo "Example:"
    echo "  $0 k3s cilium --memory 8192 --cores 4"
    echo "  $0 --cluster k8s2 --vm-id-start 210 --lb-range 192.168.40.221-192.168.40.240 --skip-image-download"
    exit 1
}

# =============================================================================
# Parse CLI arguments (override config.yml)
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ceph)
            INSTALL_CEPH=true
            shift
            ;;
        --cluster)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --vm-id-start)
            VM_ID_START="$2"
            shift 2
            ;;
        --lb-range)
            LB_IP_START="${2%-*}"
            LB_IP_END="${2#*-}"
            shift 2
            ;;
        --skip-image-download)
            SKIP_IMAGE_DOWNLOAD=true
            shift
            ;;
        --memory)
            VM_MEMORY="$2"
            shift 2
            ;;
        --cores)
            VM_CORES="$2"
            shift 2
            ;;
        --disk-size)
            VM_DISK_SIZE="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        k3s|kubeadm)
            K8S_DISTRO="$1"
            shift
            ;;
        cilium|metallb)
            LB_IMPLEMENTATION="$1"
            shift
            ;;
        *)
            # Check if it looks like a version number
            if [[ "$1" =~ ^[0-9]+\.[0-9]+$ ]]; then
                K8S_VERSION="$1"
            fi
            shift
            ;;
    esac
done

# Validate
if [[ "$K8S_DISTRO" != "k3s" && "$K8S_DISTRO" != "kubeadm" ]]; then
    echo "Error: Invalid distribution '$K8S_DISTRO'. Use 'k3s' or 'kubeadm'."
    exit 1
fi

if [[ "$LB_IMPLEMENTATION" != "cilium" && "$LB_IMPLEMENTATION" != "metallb" ]]; then
    echo "Error: Invalid loadbalancer '$LB_IMPLEMENTATION'. Use 'cilium' or 'metallb'."
    exit 1
fi

VERSION_MSG="latest"
if [[ -n "$K8S_VERSION" ]]; then
    VERSION_MSG="v$K8S_VERSION"
fi

echo "=== Deploying k8s cluster ==="
echo "  Cluster:      $CLUSTER_NAME"
echo "  Distribution: $K8S_DISTRO ($VERSION_MSG)"
echo "  LoadBalancer: $LB_IMPLEMENTATION ($LB_IP_START - $LB_IP_END)"
echo "  VM Resources: ${VM_MEMORY}MB RAM, ${VM_CORES} cores, ${VM_DISK_SIZE}GB disk"
echo "  Ceph:         $INSTALL_CEPH"
echo ""

# Persist choices for destroy.sh
echo "$K8S_DISTRO" > .k8s-distro
echo "$LB_IMPLEMENTATION" > .lb-implementation
echo "$CLUSTER_NAME" > .cluster-name
echo "$VM_ID_START" > .vm-id-start

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
TF_VARS="$TF_VARS -var=vm_count=$VM_COUNT"
TF_VARS="$TF_VARS -var=vm_memory=$VM_MEMORY"
TF_VARS="$TF_VARS -var=vm_cores=$VM_CORES"
TF_VARS="$TF_VARS -var=vm_disk_size=${VM_DISK_SIZE}G"
TF_VARS="$TF_VARS -var=ceph_disk_size=$CEPH_DISK_SIZE"

if [[ "$SKIP_IMAGE_DOWNLOAD" == "true" ]]; then
    TF_VARS="$TF_VARS -var=skip_image_download=true"
fi

# =============================================================================
# Terraform
# =============================================================================
cd terraform
terraform init -upgrade

for i in $(seq 1 $MAX_RETRIES); do
    echo "Terraform apply attempt $i of $MAX_RETRIES..."
    if TF_OUTPUT=$(terraform apply -auto-approve $TF_VARS 2>&1 | tee /dev/stderr); then
        echo "Terraform apply succeeded!"
        if echo "$TF_OUTPUT" | grep -q "0 added"; then
            echo "VMs already exist, skipping boot wait..."
        else
            echo "Waiting 30s for VMs to fully boot..."
            sleep 30
        fi
        break
    else
        if [ $i -eq $MAX_RETRIES ]; then
            echo "Terraform apply failed after $MAX_RETRIES attempts"
            exit 1
        fi
        echo "Terraform apply failed, cleaning up and retrying in ${RETRY_DELAY}s..."
        terraform destroy -auto-approve $TF_VARS || true
        sleep $RETRY_DELAY
    fi
done

# =============================================================================
# Ansible
# =============================================================================
cd ../ansible
ANSIBLE_EXTRA="-e k8s_distro=$K8S_DISTRO -e lb_implementation=$LB_IMPLEMENTATION -e install_ceph=$INSTALL_CEPH"
ANSIBLE_EXTRA="$ANSIBLE_EXTRA -e lb_ip_start=$LB_IP_START -e lb_ip_end=$LB_IP_END"

if [[ -n "$K8S_VERSION" ]]; then
    ANSIBLE_EXTRA="$ANSIBLE_EXTRA -e k8s_version=$K8S_VERSION"
fi

# Install Kubernetes
if [ "$K8S_DISTRO" = "k3s" ]; then
    echo "Installing k3s..."
    ansible-playbook $ANSIBLE_EXTRA k3s.yml
else
    echo "Installing kubeadm cluster..."
    ansible-playbook $ANSIBLE_EXTRA kubeadm.yml
fi

echo "Installing k9s on all nodes..."
ansible-playbook $ANSIBLE_EXTRA k9s.yml

echo "Installing Cilium CNI..."
ansible-playbook $ANSIBLE_EXTRA cilium.yml

# LoadBalancer
if [ "$LB_IMPLEMENTATION" = "cilium" ]; then
    echo "Configuring Cilium LoadBalancer..."
    ansible-playbook $ANSIBLE_EXTRA cilium-lb.yml
else
    echo "Installing MetalLB LoadBalancer..."
    ansible-playbook $ANSIBLE_EXTRA metallb.yml
fi

# Ceph storage
if [ "$INSTALL_CEPH" = true ]; then
    echo "Installing Rook-Ceph..."
    ansible-playbook $ANSIBLE_EXTRA rook-ceph.yml
fi

# Applications (based on config)
if [ "$APP_DASHBOARD" = "true" ]; then
    echo "Installing Kubernetes Dashboard..."
    ansible-playbook $ANSIBLE_EXTRA dashboard.yml
fi

if [ "$APP_DEMO" = "true" ]; then
    echo "Deploying Demo Apps..."
    ansible-playbook $ANSIBLE_EXTRA demo-app.yml
    ansible-playbook $ANSIBLE_EXTRA demo-app-2.yml
fi

if [ "$INSTALL_CEPH" = true ]; then
    echo "Deploying Ceph S3 Object Storage..."
    ansible-playbook $ANSIBLE_EXTRA ceph-s3.yml
fi

if [ "$APP_ARGOCD" = "true" ]; then
    echo "Deploying Argo CD..."
    ansible-playbook $ANSIBLE_EXTRA \
        -e argocd_repo_url="$ARGOCD_REPO_URL" \
        -e argocd_path="$ARGOCD_PATH" \
        -e argocd_branch="$ARGOCD_BRANCH" \
        -e argocd_app_name="$ARGOCD_APP_NAME" \
        argocd.yml
fi

if [ "$APP_KEYCLOAK" = "true" ]; then
    echo "Deploying Keycloak..."
    ansible-playbook $ANSIBLE_EXTRA keycloak.yml
    ansible-playbook $ANSIBLE_EXTRA keycloak-demo-app.yml
fi

cd ..

# =============================================================================
# Output
# =============================================================================
MASTER_IP=$(grep 'ansible_host=' ansible/inventory.ini | head -1 | sed 's/.*ansible_host=//')

export KUBECONFIG=$(pwd)/kubeconfig
DEMO_LB_IP=$(kubectl -n demo get svc nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
DEMO2_LB_IP=$(kubectl -n demo2 get svc nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
ARGOCD_LB_IP=$(kubectl -n argocd get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
KEYCLOAK_LB_IP=$(kubectl -n keycloak get svc keycloak -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")

echo ""
echo "=== Deployment complete ==="
echo ""
echo "Cluster: $CLUSTER_NAME ($K8S_DISTRO, $LB_IMPLEMENTATION)"
echo ""
echo "Access:"
echo "  export KUBECONFIG=$(pwd)/kubeconfig"
echo ""
echo "Services:"
[ "$APP_DASHBOARD" = "true" ] && echo "  Dashboard:    https://${MASTER_IP}:30443"
[ "$APP_DEMO" = "true" ] && echo "  Demo App 1:   http://${DEMO_LB_IP}:8081"
[ "$APP_DEMO" = "true" ] && echo "  Demo App 2:   http://${DEMO2_LB_IP}:8082"
[ "$APP_ARGOCD" = "true" ] && echo "  Argo CD:      https://${ARGOCD_LB_IP}  (see argocd-credentials.txt)"
[ "$APP_KEYCLOAK" = "true" ] && echo "  Keycloak:     http://${KEYCLOAK_LB_IP}:8080  (see keycloak-credentials.txt)"
[ "$INSTALL_CEPH" = true ] && echo "  S3 Endpoint:  See s3-credentials.txt"
echo ""
echo "Nodes:"
grep 'ansible_host=' ansible/inventory.ini | while read -r line; do
    NODE_NAME=$(echo "$line" | awk '{print $1}')
    NODE_IP=$(echo "$line" | sed 's/.*ansible_host=//')
    echo "  ${NODE_NAME}: ${NODE_IP}"
done
echo ""

# =============================================================================
# Save deployment artifacts locally (always) and to NFS (if enabled)
# =============================================================================
echo "=== Saving deployment artifacts ==="

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="deployment_${CLUSTER_NAME}_${TIMESTAMP}"
LOCAL_BACKUP_DIR="$(pwd)/deployments/${BACKUP_DIR}"

# Create local backup directory
mkdir -p "$LOCAL_BACKUP_DIR"

# Collect all deployment artifacts
echo "Collecting deployment artifacts..."

# Kubeconfig
[ -f "kubeconfig" ] && cp kubeconfig "$LOCAL_BACKUP_DIR/"

# Credential files
[ -f "argocd-credentials.txt" ] && cp argocd-credentials.txt "$LOCAL_BACKUP_DIR/"
[ -f "keycloak-credentials.txt" ] && cp keycloak-credentials.txt "$LOCAL_BACKUP_DIR/"
[ -f "s3-credentials.txt" ] && cp s3-credentials.txt "$LOCAL_BACKUP_DIR/"
[ -f "dashboard-token.txt" ] && cp dashboard-token.txt "$LOCAL_BACKUP_DIR/"

# Inventory and config
[ -f "ansible/inventory.ini" ] && cp ansible/inventory.ini "$LOCAL_BACKUP_DIR/"
[ -f "config.yml" ] && cp config.yml "$LOCAL_BACKUP_DIR/"

# Create a summary file
cat > "$LOCAL_BACKUP_DIR/deployment-summary.txt" << SUMMARY_EOF
Kubernetes Deployment Summary
=============================
Timestamp: $(date)
Cluster Name: $CLUSTER_NAME
Distribution: $K8S_DISTRO
LoadBalancer: $LB_IMPLEMENTATION
LoadBalancer IP Range: $LB_IP_START - $LB_IP_END

VM Resources:
  Memory: ${VM_MEMORY}MB
  Cores: $VM_CORES
  Disk: ${VM_DISK_SIZE}GB

Nodes:
$(grep 'ansible_host=' ansible/inventory.ini | while read -r line; do
    NODE_NAME=$(echo "$line" | awk '{print $1}')
    NODE_IP=$(echo "$line" | sed 's/.*ansible_host=//')
    echo "  ${NODE_NAME}: ${NODE_IP}"
done)

Services:
  Dashboard: https://${MASTER_IP}:30443
  Demo App 1: http://${DEMO_LB_IP}:8081
  Demo App 2: http://${DEMO2_LB_IP}:8082
  Argo CD: https://${ARGOCD_LB_IP}
  Keycloak: http://${KEYCLOAK_LB_IP}:8080

Shared IP Groups (Cilium lb-ipam-sharing-key):
  Platform: ArgoCD (:80/:443), Keycloak (:8080), Keycloak Demo (:8086), Headlamp (:4466), Grafana (:3000), Prometheus (:9090), Kibana (:5601)
  Apps: Demo1 (:8081), Demo2 (:8082), Hello-A (:8083), Hello-B (:8084), Hello-C (:8085), Gitea (:3000/:22), B0k3ts (:8088/:8089)
SUMMARY_EOF

echo "Artifacts saved locally to: $LOCAL_BACKUP_DIR"

# Additionally copy to remote storage if enabled
if [ "$BACKUP_ENABLED" = "true" ]; then
    # Check if local mount path exists (already mounted share)
    if [ -n "$BACKUP_LOCAL_MOUNT" ] && [ -d "$BACKUP_LOCAL_MOUNT" ]; then
        echo "Copying artifacts to mounted share..."
        TARGET_DIR="${BACKUP_LOCAL_MOUNT}/${BACKUP_PATH}"
        mkdir -p "$TARGET_DIR"
        cp -r "$LOCAL_BACKUP_DIR" "$TARGET_DIR/"
        echo "Artifacts copied to: ${TARGET_DIR}/${BACKUP_DIR}"

    # Fall back to NFS mount if local mount not available
    elif [ -n "$NFS_SERVER" ] && [ -n "$NFS_SHARE" ]; then
        echo "Copying artifacts to NFS..."
        NFS_MOUNT_POINT="/tmp/nfs_backup_mount_$$"
        mkdir -p "$NFS_MOUNT_POINT"

        if mount -t nfs "${NFS_SERVER}:${NFS_SHARE}" "$NFS_MOUNT_POINT" 2>/dev/null || \
           mount_nfs "${NFS_SERVER}:${NFS_SHARE}" "$NFS_MOUNT_POINT" 2>/dev/null; then

            TARGET_DIR="${NFS_MOUNT_POINT}/${BACKUP_PATH}"
            mkdir -p "$TARGET_DIR"
            cp -r "$LOCAL_BACKUP_DIR" "$TARGET_DIR/"

            umount "$NFS_MOUNT_POINT" 2>/dev/null || diskutil unmount "$NFS_MOUNT_POINT" 2>/dev/null || true
            rmdir "$NFS_MOUNT_POINT" 2>/dev/null || true

            echo "Artifacts copied to NFS: ${NFS_SERVER}:${NFS_SHARE}/${BACKUP_PATH}/${BACKUP_DIR}"
        else
            echo "Warning: Could not mount NFS share ${NFS_SERVER}:${NFS_SHARE}"
            echo "You can manually copy with: cp -r $LOCAL_BACKUP_DIR /path/to/mount/${BACKUP_PATH}/"
        fi
    else
        echo "Warning: Backup enabled but no mount path or NFS settings configured"
    fi
fi

echo ""
