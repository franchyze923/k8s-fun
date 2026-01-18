#!/bin/bash
set -e

cd "$(dirname "$0")"

MAX_RETRIES=3
RETRY_DELAY=10

echo "=== Deploying k8s cluster ==="

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
echo "Installing k3s..."
ansible-playbook k3s.yml

echo "Installing Cilium CNI..."
ansible-playbook cilium.yml

echo "Configuring Cilium LoadBalancer..."
ansible-playbook cilium-lb.yml

echo "Installing Rook-Ceph..."
ansible-playbook rook-ceph.yml

echo "Installing Kubernetes Dashboard..."
ansible-playbook dashboard.yml

echo "Deploying Demo App..."
ansible-playbook demo-app.yml

echo "Deploying Ceph S3 Object Storage..."
ansible-playbook ceph-s3.yml

cd ..

# Get master IP from inventory
MASTER_IP=$(grep 'ansible_host=' ansible/inventory.ini | head -1 | sed 's/.*ansible_host=//')

# Get LoadBalancer IP for demo app
export KUBECONFIG=$(pwd)/kubeconfig
DEMO_LB_IP=$(kubectl -n demo get svc nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")

echo ""
echo "=== Deployment complete ==="
echo ""
echo "To access the cluster:"
echo "  export KUBECONFIG=$(pwd)/kubeconfig"
echo ""
echo "Dashboard:  https://${MASTER_IP}:30443"
echo "Demo App:   http://${DEMO_LB_IP}"
echo "S3 Endpoint: See s3-credentials.txt"
echo ""
echo "Dashboard token: $(pwd)/dashboard-token.txt"
echo "S3 credentials:  $(pwd)/s3-credentials.txt"
echo ""
