#!/bin/bash
set -e

cd "$(dirname "$0")"

# Read distro for informational purposes
K8S_DISTRO="unknown"
if [ -f .k8s-distro ]; then
    K8S_DISTRO=$(cat .k8s-distro)
fi

echo "=== Destroying k8s cluster (distro: $K8S_DISTRO) ==="
cd terraform
terraform destroy -auto-approve
cd ..

echo "=== Cleaning up generated files ==="
rm -f kubeconfig dashboard-token.txt s3-credentials.txt ansible/inventory.ini .k8s-distro
echo "=== Cluster destroyed ==="
