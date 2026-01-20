# k3s on Proxmox

Automated deployment of a k3s Kubernetes cluster on Proxmox VMs using Terraform and Ansible.

## What You Get

- **3-node k3s cluster** (1 master + 2 workers) on Rocky Linux 9
- **Cilium CNI** with L2 LoadBalancer support
- **Rook-Ceph storage** (block storage + S3-compatible object storage)
- **Kubernetes Dashboard**
- **Code-Server** (VS Code in browser)
- **Two demo nginx apps** with separate LoadBalancer IPs

## Prerequisites

- Proxmox server with API access
- Local machine with:
  - Terraform
  - Ansible
  - SSH key pair

## Quick Start

### 1. Clone the repo

```bash
git clone https://github.com/franchyze923/k8s-fun.git
cd k8s-fun
```

### 2. Configure Proxmox credentials

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars`:
```hcl
proxmox_host     = "192.168.1.100"      # Your Proxmox IP
proxmox_user     = "root@pam"
proxmox_password = "your-password"
proxmox_node     = "pve"                 # Your Proxmox node name
ssh_public_key   = "ssh-rsa AAAA..."     # Your SSH public key
vm_storage       = "local-lvm"           # Storage for VMs
```

### 3. Deploy everything

```bash
./deploy.sh
```

This takes about 15-20 minutes and will:
1. Create 3 VMs in Proxmox (Terraform)
2. Install k3s cluster (Ansible)
3. Install Cilium CNI with LoadBalancer
4. Deploy Rook-Ceph storage
5. Install Kubernetes Dashboard
6. Deploy demo apps (2 apps with LoadBalancer IPs)
7. Deploy S3 object storage
8. Deploy Code-Server (VS Code in browser)

### 4. Access your cluster

After deployment, you'll see output like:
```
Dashboard:    https://192.168.40.14:30443
Demo App 1:   http://192.168.40.200
Demo App 2:   http://192.168.40.201
Code-Server:  http://192.168.40.202:8443  (password: changeme)
S3 Endpoint:  See s3-credentials.txt
```

Use the kubeconfig:
```bash
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get nodes
```

## Destroy Everything

```bash
./destroy.sh
```

This removes all VMs and cleans up generated files.

## File Structure

```
.
├── deploy.sh                 # Main deployment script
├── destroy.sh                # Cleanup script
├── terraform/
│   ├── main.tf               # VM definitions
│   ├── variables.tf          # Configurable variables
│   ├── providers.tf          # Proxmox provider config
│   └── terraform.tfvars      # Your credentials (git-ignored)
└── ansible/
    ├── k3s.yml               # k3s installation
    ├── cilium.yml            # Cilium CNI
    ├── cilium-lb.yml         # L2 LoadBalancer config
    ├── rook-ceph.yml         # Ceph storage
    ├── dashboard.yml         # Kubernetes Dashboard
    ├── demo-app.yml          # Demo nginx app 1
    ├── demo-app-2.yml        # Demo nginx app 2
    ├── ceph-s3.yml           # S3 object storage
    └── code-server.yml       # VS Code in browser
```

## Configuration Options

Edit `terraform/variables.tf` defaults or override in `terraform.tfvars`:

| Variable | Default | Description |
|----------|---------|-------------|
| `vm_count` | 3 | Number of VMs (1 master + N-1 workers) |
| `vm_memory` | 4096 | RAM per VM (MB) |
| `vm_cores` | 2 | CPU cores per VM |
| `vm_disk_size` | 32 | OS disk size (GB) |
| `ceph_disk_size` | 20 | Ceph OSD disk size (GB) |

## LoadBalancer IP Pool

The Cilium L2 LoadBalancer uses IPs from `192.168.40.200-220`. To change this, edit `ansible/cilium-lb.yml`:

```yaml
spec:
  blocks:
  - start: "192.168.40.200"
    stop: "192.168.40.220"
```

Make sure these IPs are not used by your DHCP server.

## Using S3 Storage

After deployment, credentials are saved to `s3-credentials.txt`:

```bash
# Source the credentials
source s3-credentials.txt

# Create a bucket
aws --endpoint-url $S3_ENDPOINT s3 mb s3://my-bucket

# Upload a file
aws --endpoint-url $S3_ENDPOINT s3 cp myfile.txt s3://my-bucket/

# List buckets
aws --endpoint-url $S3_ENDPOINT s3 ls
```

## Running Individual Playbooks

If you need to re-run a specific component:

```bash
cd ansible

# Just reinstall Cilium
ansible-playbook cilium.yml

# Just deploy the demo app
ansible-playbook demo-app.yml

# Just configure S3
ansible-playbook ceph-s3.yml
```

## Troubleshooting

### VMs not getting IPs
- Check Proxmox network bridge configuration
- Ensure DHCP is available on the VM network

### Cilium not ready
- Wait longer (can take 2-3 minutes)
- Check: `kubectl -n kube-system get pods -l k8s-app=cilium`

### Ceph OSDs not starting
- Ensure VMs have the second disk (ceph_disk_size)
- Check: `kubectl -n rook-ceph get pods`

### LoadBalancer IP not reachable
- Ensure L2 announcements are enabled: `cilium config view | grep l2`
- Check IP pool: `kubectl get ciliumloadbalancerippool`
- Verify interface regex matches your VMs: `ip link show`

## Components

| Component | Version | Purpose |
|-----------|---------|---------|
| Rocky Linux | 9 | VM OS |
| k3s | latest | Lightweight Kubernetes |
| Cilium | 1.16.0 | CNI + LoadBalancer |
| Rook-Ceph | 1.14 | Storage (block + S3) |
| Dashboard | 2.7.0 | Web UI |
