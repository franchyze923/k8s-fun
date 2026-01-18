#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "=== Destroying k8s cluster ==="
cd terraform
terraform destroy -auto-approve
cd ..

echo "=== Cleaning up generated files ==="
rm -f kubeconfig dashboard-token.txt s3-credentials.txt ansible/inventory.ini
echo "=== Cluster destroyed ==="
