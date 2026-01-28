#!/bin/bash
set -eo pipefail

cd "$(dirname "$0")"

INSTALL_CEPH=false
K8S_DISTRO=""
LB_IMPLEMENTATION=""
K8S_VERSION=""
MAX_RETRIES=3
RETRY_DELAY=10

usage() {
    echo "Usage: $0 [k3s|kubeadm] [cilium|metallb] [k8s-version] [--ceph]"
    echo "  k3s      - Lightweight Kubernetes (default)"
    echo "  kubeadm  - Standard Kubernetes with kubeadm"
    echo ""
    echo "  cilium   - Cilium L2 LoadBalancer (default)"
    echo "  metallb  - MetalLB LoadBalancer"
    echo ""
    echo "  k8s-version - Kubernetes version (e.g., 1.30, 1.29). Default: latest"
    echo ""
    echo "  --ceph   - Install Rook-Ceph storage and S3 (optional)"
    exit 1
}

# Parse arguments
for arg in "$@"; do
    if [[ "$arg" == "--ceph" ]]; then
        INSTALL_CEPH=true
    elif [[ -z "$K8S_DISTRO" ]]; then
        K8S_DISTRO="$arg"
    elif [[ -z "$LB_IMPLEMENTATION" ]]; then
        LB_IMPLEMENTATION="$arg"
    elif [[ -z "$K8S_VERSION" ]]; then
        K8S_VERSION="$arg"
    fi
done

K8S_DISTRO="${K8S_DISTRO:-k3s}"
LB_IMPLEMENTATION="${LB_IMPLEMENTATION:-cilium}"

if [[ "$K8S_DISTRO" != "k3s" && "$K8S_DISTRO" != "kubeadm" ]]; then
    usage
fi

if [[ "$LB_IMPLEMENTATION" != "cilium" && "$LB_IMPLEMENTATION" != "metallb" ]]; then
    usage
fi

VERSION_MSG="latest"
if [[ -n "$K8S_VERSION" ]]; then
    VERSION_MSG="v$K8S_VERSION"
fi

echo "=== Deploying k8s cluster (distro: $K8S_DISTRO, lb: $LB_IMPLEMENTATION, version: $VERSION_MSG) ==="

# Persist distro choice for destroy.sh
echo "$K8S_DISTRO" > .k8s-distro
echo "$LB_IMPLEMENTATION" > .lb-implementation

# Terraform apply with retries
cd terraform

# Initialize terraform if needed
terraform init -upgrade

for i in $(seq 1 $MAX_RETRIES); do
    echo "Terraform apply attempt $i of $MAX_RETRIES..."
    if TF_OUTPUT=$(terraform apply -auto-approve 2>&1 | tee /dev/stderr); then
        echo "Terraform apply succeeded!"
        # Check if VMs were created (not just "0 added")
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
        terraform destroy -auto-approve || true
        sleep $RETRY_DELAY
    fi
done

# Run ansible playbooks
cd ../ansible
ANSIBLE_EXTRA="-e k8s_distro=$K8S_DISTRO -e lb_implementation=$LB_IMPLEMENTATION -e install_ceph=$INSTALL_CEPH"
if [[ -n "$K8S_VERSION" ]]; then
    ANSIBLE_EXTRA="$ANSIBLE_EXTRA -e k8s_version=$K8S_VERSION"
fi

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

if [ "$LB_IMPLEMENTATION" = "cilium" ]; then
    echo "Configuring Cilium LoadBalancer..."
    ansible-playbook $ANSIBLE_EXTRA cilium-lb.yml
else
    echo "Installing MetalLB LoadBalancer..."
    ansible-playbook $ANSIBLE_EXTRA metallb.yml
fi

if [ "$INSTALL_CEPH" = true ]; then
    echo "Installing Rook-Ceph..."
    ansible-playbook $ANSIBLE_EXTRA rook-ceph.yml
fi

echo "Installing Kubernetes Dashboard..."
ansible-playbook $ANSIBLE_EXTRA dashboard.yml

echo "Deploying Demo App..."
ansible-playbook $ANSIBLE_EXTRA demo-app.yml

echo "Deploying Demo App 2..."
ansible-playbook $ANSIBLE_EXTRA demo-app-2.yml

if [ "$INSTALL_CEPH" = true ]; then
    echo "Deploying Ceph S3 Object Storage..."
    ansible-playbook $ANSIBLE_EXTRA ceph-s3.yml
fi

echo "Deploying Argo CD..."
ansible-playbook $ANSIBLE_EXTRA argocd.yml

echo "Deploying Keycloak..."
ansible-playbook $ANSIBLE_EXTRA keycloak.yml

echo "Deploying Keycloak Demo App..."
ansible-playbook $ANSIBLE_EXTRA keycloak-demo-app.yml

cd ..

# Get master IP from inventory
MASTER_IP=$(grep 'ansible_host=' ansible/inventory.ini | head -1 | sed 's/.*ansible_host=//')

# Get LoadBalancer IPs for apps
export KUBECONFIG=$(pwd)/kubeconfig
DEMO_LB_IP=$(kubectl -n demo get svc nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
DEMO2_LB_IP=$(kubectl -n demo2 get svc nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
ARGOCD_LB_IP=$(kubectl -n argocd get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
KEYCLOAK_LB_IP=$(kubectl -n keycloak get svc keycloak -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
KEYCLOAK_DEMO_LB_IP=$(kubectl -n keycloak get svc keycloak-demo-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")

echo ""
echo "=== Deployment complete (distro: $K8S_DISTRO, lb: $LB_IMPLEMENTATION, version: $VERSION_MSG) ==="
echo ""
echo "To access the cluster:"
echo "  export KUBECONFIG=$(pwd)/kubeconfig"
echo ""
echo "Dashboard:    https://${MASTER_IP}:30443"
echo "Demo App 1:   http://${DEMO_LB_IP}"
echo "Demo App 2:   http://${DEMO2_LB_IP}"
echo "Argo CD:      https://${ARGOCD_LB_IP}  (see argocd-credentials.txt)"
echo "Keycloak:     http://${KEYCLOAK_LB_IP}:8080  (see keycloak-credentials.txt)"
echo "Keycloak Demo: http://${KEYCLOAK_DEMO_LB_IP}  (OIDC demo app)"
if [ "$INSTALL_CEPH" = true ]; then
    echo "S3 Endpoint:  See s3-credentials.txt"
fi
echo ""
echo "Node IPs:"
grep 'ansible_host=' ansible/inventory.ini | while read -r line; do
    NODE_NAME=$(echo "$line" | awk '{print $1}')
    NODE_IP=$(echo "$line" | sed 's/.*ansible_host=//')
    echo "  ${NODE_NAME}: ${NODE_IP}"
done
echo ""
echo "Dashboard token:    $(pwd)/dashboard-token.txt"
echo "ArgoCD credentials: $(pwd)/argocd-credentials.txt"
echo "Keycloak creds:     $(pwd)/keycloak-credentials.txt"
if [ "$INSTALL_CEPH" = true ]; then
    echo "S3 credentials:     $(pwd)/s3-credentials.txt"
fi
echo ""
