# k3s on Proxmox

Automated deployment of a k3s Kubernetes cluster on Proxmox VMs using Terraform and Ansible.

## What You Get

- **3-node k3s cluster** (1 master + 2 workers) on Rocky Linux 9
- **Cilium CNI** with choice of L2 LoadBalancer (Cilium or MetalLB)
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

**Default deployment (k3s + Cilium LoadBalancer):**
```bash
./deploy.sh
```

**Alternative options:**
```bash
# Use kubeadm instead of k3s
./deploy.sh kubeadm

# Use MetalLB instead of Cilium LoadBalancer
./deploy.sh k3s metallb

# Combine options: kubeadm + MetalLB
./deploy.sh kubeadm metallb
```

This takes about 15-20 minutes and will:
1. Create 3 VMs in Proxmox (Terraform)
2. Install k3s or kubeadm cluster (Ansible)
3. Install Cilium CNI
4. Install LoadBalancer (Cilium L2 or MetalLB)
5. Deploy Rook-Ceph storage
6. Install Kubernetes Dashboard
7. Deploy demo apps (2 apps with LoadBalancer IPs)
8. Deploy S3 object storage
9. Deploy Code-Server (VS Code in browser)

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
├── ansible/
│   ├── k3s.yml               # k3s installation
│   ├── kubeadm.yml           # kubeadm installation
│   ├── cilium.yml            # Cilium CNI
│   ├── cilium-lb.yml         # Cilium L2 LoadBalancer config
│   ├── metallb.yml           # MetalLB LoadBalancer
│   ├── rook-ceph.yml         # Ceph storage
│   ├── dashboard.yml         # Kubernetes Dashboard
│   ├── demo-app.yml          # Demo nginx app 1
│   ├── demo-app-2.yml        # Demo nginx app 2
│   ├── ceph-s3.yml           # S3 object storage
│   └── code-server.yml       # VS Code in browser
└── manifests/
    ├── cilium-lb.yaml        # Cilium LB manifests
    ├── metallb.yaml          # MetalLB manifests
    ├── dashboard.yaml        # Dashboard config
    ├── demo-app.yaml         # Demo app 1 manifests
    ├── demo-app-2.yaml       # Demo app 2 manifests
    ├── ceph-s3.yaml          # S3 config
    └── code-server.yaml      # Code-Server manifests
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

## LoadBalancer Options

### Cilium L2 LoadBalancer (Default)

The Cilium L2 LoadBalancer uses IPs from `192.168.40.200-220`. To change this, edit `ansible/cilium-lb.yml`:

```yaml
spec:
  blocks:
  - start: "192.168.40.200"
    stop: "192.168.40.220"
```

Cilium's L2 announcements are built-in to the CNI, providing a lightweight solution without additional components.

### MetalLB LoadBalancer

To use MetalLB instead of Cilium's L2 LoadBalancer:

```bash
./deploy.sh k3s metallb
```

MetalLB uses the same IP pool (`192.168.40.200-220`). To change this, edit `ansible/metallb.yml`:

```yaml
spec:
  addresses:
  - 192.168.40.200-192.168.40.220
```

**Note:** Make sure these IPs are not used by your DHCP server, regardless of which LoadBalancer you choose.

**When to use each:**
- **Cilium L2**: Simpler, fewer components, integrated with CNI
- **MetalLB**: Industry standard, more mature, better for production use cases

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

# Configure Cilium LoadBalancer
ansible-playbook cilium-lb.yml

# Install MetalLB (alternative to Cilium LB)
ansible-playbook metallb.yml

# Just deploy the demo app
ansible-playbook demo-app.yml

# Just configure S3
ansible-playbook ceph-s3.yml
```

**Note:** When switching between Cilium LB and MetalLB, you'll need to reinstall Cilium with the correct settings. The `lb_implementation` variable controls whether L2 announcements are enabled in Cilium.

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

**For Cilium LoadBalancer:**
- Ensure L2 announcements are enabled: `cilium config view | grep l2`
- Check IP pool: `kubectl get ciliumloadbalancerippool`
- Verify interface regex matches your VMs: `ip link show`

**For MetalLB:**
- Check MetalLB pods: `kubectl get pods -n metallb-system`
- Check IP pool: `kubectl get ipaddresspool -n metallb-system`
- Check L2 advertisement: `kubectl get l2advertisement -n metallb-system`
- View logs: `kubectl logs -n metallb-system -l app=metallb`

## Components

| Component | Version | Purpose |
|-----------|---------|---------|
| Rocky Linux | 9 | VM OS |
| k3s / kubeadm | latest / 1.30 | Kubernetes distribution |
| Cilium | 1.16.0 | CNI (+ optional LoadBalancer) |
| MetalLB | 0.14.5 | Optional LoadBalancer |
| Rook-Ceph | 1.14 | Storage (block + S3) |
| Dashboard | 2.7.0 | Web UI |
| Code-Server | latest | Browser-based VS Code |
