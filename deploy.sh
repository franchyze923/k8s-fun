#!/bin/bash
set -e

cd "$(dirname "$0")"

K8S_DISTRO="${1:-k3s}"
LB_IMPLEMENTATION="${2:-cilium}"
MAX_RETRIES=3
RETRY_DELAY=10

if [[ "$K8S_DISTRO" != "k3s" && "$K8S_DISTRO" != "kubeadm" ]]; then
    echo "Usage: $0 [k3s|kubeadm] [cilium|metallb]"
    echo "  k3s      - Lightweight Kubernetes (default)"
    echo "  kubeadm  - Standard Kubernetes with kubeadm"
    echo ""
    echo "  cilium   - Cilium L2 LoadBalancer (default)"
    echo "  metallb  - MetalLB LoadBalancer"
    exit 1
fi

if [[ "$LB_IMPLEMENTATION" != "cilium" && "$LB_IMPLEMENTATION" != "metallb" ]]; then
    echo "Usage: $0 [k3s|kubeadm] [cilium|metallb]"
    echo "  k3s      - Lightweight Kubernetes (default)"
    echo "  kubeadm  - Standard Kubernetes with kubeadm"
    echo ""
    echo "  cilium   - Cilium L2 LoadBalancer (default)"
    echo "  metallb  - MetalLB LoadBalancer"
    exit 1
fi

echo "=== Deploying k8s cluster (distro: $K8S_DISTRO, lb: $LB_IMPLEMENTATION) ==="

# Persist distro choice for destroy.sh
echo "$K8S_DISTRO" > .k8s-distro
echo "$LB_IMPLEMENTATION" > .lb-implementation

# Terraform apply with retries
cd terraform
for i in $(seq 1 $MAX_RETRIES); do
    echo "Terraform apply attempt $i of $MAX_RETRIES..."
    if terraform apply -auto-approve; then
        echo "Terraform apply succeeded!"
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

# Wait for VMs to be fully ready
echo "Waiting 30s for VMs to fully boot..."
sleep 30

# Run ansible playbooks
cd ../ansible
ANSIBLE_EXTRA="-e k8s_distro=$K8S_DISTRO -e lb_implementation=$LB_IMPLEMENTATION"

if [ "$K8S_DISTRO" = "k3s" ]; then
    echo "Installing k3s..."
    ansible-playbook $ANSIBLE_EXTRA k3s.yml
else
    echo "Installing kubeadm cluster..."
    ansible-playbook $ANSIBLE_EXTRA kubeadm.yml
fi

echo "Installing Cilium CNI..."
ansible-playbook $ANSIBLE_EXTRA cilium.yml

if [ "$LB_IMPLEMENTATION" = "cilium" ]; then
    echo "Configuring Cilium LoadBalancer..."
    ansible-playbook $ANSIBLE_EXTRA cilium-lb.yml
else
    echo "Installing MetalLB LoadBalancer..."
    ansible-playbook $ANSIBLE_EXTRA metallb.yml
fi

echo "Installing Rook-Ceph..."
ansible-playbook $ANSIBLE_EXTRA rook-ceph.yml

echo "Installing Kubernetes Dashboard..."
ansible-playbook $ANSIBLE_EXTRA dashboard.yml

echo "Deploying Demo App..."
ansible-playbook $ANSIBLE_EXTRA demo-app.yml

echo "Deploying Demo App 2..."
ansible-playbook $ANSIBLE_EXTRA demo-app-2.yml

echo "Deploying Ceph S3 Object Storage..."
ansible-playbook $ANSIBLE_EXTRA ceph-s3.yml

echo "Deploying Code-Server (VS Code in browser)..."
ansible-playbook $ANSIBLE_EXTRA code-server.yml

cd ..

# Get master IP from inventory
MASTER_IP=$(grep 'ansible_host=' ansible/inventory.ini | head -1 | sed 's/.*ansible_host=//')

# Get LoadBalancer IPs for apps
export KUBECONFIG=$(pwd)/kubeconfig
DEMO_LB_IP=$(kubectl -n demo get svc nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
DEMO2_LB_IP=$(kubectl -n demo2 get svc nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
CODE_SERVER_IP=$(kubectl -n code-server get svc code-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")

echo ""
echo "=== Deployment complete (distro: $K8S_DISTRO, lb: $LB_IMPLEMENTATION) ==="
echo ""
echo "To access the cluster:"
echo "  export KUBECONFIG=$(pwd)/kubeconfig"
echo ""
echo "Dashboard:    https://${MASTER_IP}:30443"
echo "Demo App 1:   http://${DEMO_LB_IP}"
echo "Demo App 2:   http://${DEMO2_LB_IP}"
echo "Code-Server:  http://${CODE_SERVER_IP}:8443  (password: changeme)"
echo "S3 Endpoint:  See s3-credentials.txt"
echo ""
echo "Dashboard token: $(pwd)/dashboard-token.txt"
echo "S3 credentials:  $(pwd)/s3-credentials.txt"
echo ""
