# k3s on Proxmox

Automated deployment of a Kubernetes cluster on Proxmox VMs using Terraform and Ansible.

## What You Get

- **3-node cluster** (1 master + 2 workers) on Rocky Linux 9
- **k3s or kubeadm** - your choice of Kubernetes distribution
- **Cilium CNI** with L2 LoadBalancer (or MetalLB)
- **Optional apps**: Dashboard, Argo CD, Keycloak, Code-Server, Demo apps
- **Optional storage**: Rook-Ceph (block + S3)
- **Multi-cluster support** - run multiple clusters on the same Proxmox

## Quick Start

### 1. Clone and configure

```bash
git clone https://github.com/franchyze923/k8s-fun.git
cd k8s-fun

# Copy config templates
cp config.yml.example config.yml
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# Edit with your values
# - config.yml: IPs, cluster settings, app toggles
# - terraform/terraform.tfvars: Proxmox password and SSH key
```

### 2. Edit config.yml

All deployment settings are in `config.yml` (gitignored for security):

```yaml
proxmox:
  host: "192.168.40.10"
  node: "pve"
  storage: "local-lvm"

cluster:
  name: "k8s"
  node_count: 3

vm:
  memory: 4096
  cores: 2
  disk_size: 32

networking:
  loadbalancer: "cilium"
  lb_ip_start: "192.168.40.200"
  lb_ip_end: "192.168.40.220"

apps:
  dashboard: true
  argocd: true
  keycloak: true
  # ... etc
```

### 3. Deploy

```bash
./deploy.sh
```

Or override config via CLI:

```bash
./deploy.sh kubeadm metallb --memory 8192 --cores 4
```

### 4. Access

```bash
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get nodes
```

## Configuration

### config.yml (recommended)

Edit `config.yml` to configure your deployment. All settings in one place:

| Section | Settings |
|---------|----------|
| `proxmox` | host, user, node, storage, network_bridge |
| `cluster` | name, vm_id_start, node_count |
| `kubernetes` | distribution (k3s/kubeadm), version |
| `vm` | memory, cores, disk_size |
| `networking` | loadbalancer, lb_ip_start, lb_ip_end |
| `storage` | ceph_enabled, ceph_disk_size |
| `apps` | dashboard, demo_apps, argocd, keycloak |
| `argocd` | repo_url, path, branch, app_name |
| `backup` | enabled, local_mount, path, nfs_server, nfs_share |

### CLI Overrides

CLI flags override config.yml values:

```bash
./deploy.sh [k3s|kubeadm] [cilium|metallb] [options]

Options:
  --memory MB          RAM per VM (default: from config.yml)
  --cores N            CPU cores per VM
  --disk-size GB       OS disk size
  --cluster NAME       Cluster name prefix
  --vm-id-start N      Starting VM ID
  --lb-range START-END LoadBalancer IP range
  --ceph               Enable Ceph storage
  --skip-image-download Skip cloud image download
```

### Credentials

Sensitive data stays in `terraform/terraform.tfvars`:

```hcl
proxmox_password = "your-password"
ssh_public_key   = "ssh-rsa AAAA..."
```

## Multi-Cluster

Deploy multiple clusters by changing cluster settings:

**In config.yml:**
```yaml
cluster:
  name: "k8s2"
  vm_id_start: 210

networking:
  lb_ip_start: "192.168.40.221"
  lb_ip_end: "192.168.40.240"
```

**Or via CLI:**
```bash
./deploy.sh --cluster k8s2 --vm-id-start 210 --lb-range 192.168.40.221-192.168.40.240 --skip-image-download
```

## Destroy

```bash
./destroy.sh                    # Destroys cluster from last deploy
./destroy.sh --cluster k8s2     # Destroys specific cluster
```

## Backup

Deployment artifacts (kubeconfig, credentials, config) are automatically saved to `./deployments/` after each deploy.

To also copy to a NAS/NFS share, configure in `config.yml`:

```yaml
backup:
  enabled: true
  local_mount: "/Volumes/MyNAS"     # If already mounted
  path: "k8s_deployments"           # Subfolder on the share
  nfs_server: "192.168.x.x"         # Fallback: mount NFS if local_mount unavailable
  nfs_share: "/mnt/share"
```

## File Structure

```
.
├── config.yml.example    # Template config (copy to config.yml)
├── config.yml            # Your settings (git-ignored)
├── deploy.sh             # Main deployment script
├── destroy.sh            # Cleanup script
├── deployments/          # Backup artifacts (git-ignored)
├── terraform/
│   ├── main.tf           # VM definitions
│   ├── variables.tf      # Variable definitions
│   └── terraform.tfvars  # Credentials (git-ignored)
└── ansible/
    ├── k3s.yml           # k3s installation
    ├── kubeadm.yml       # kubeadm installation
    ├── cilium.yml        # Cilium CNI
    ├── cilium-lb.yml     # Cilium LoadBalancer
    ├── metallb.yml       # MetalLB LoadBalancer
    ├── dashboard.yml     # Kubernetes Dashboard
    ├── argocd.yml        # Argo CD
    ├── keycloak.yml      # Keycloak
    └── ...
```

## Components

| Component | Version | Purpose |
|-----------|---------|---------|
| Rocky Linux | 9 | VM OS |
| k3s / kubeadm | latest | Kubernetes |
| Cilium | 1.16.0 | CNI + LoadBalancer |
| MetalLB | 0.14.5 | Alternative LoadBalancer |
| Rook-Ceph | 1.14 | Storage (optional) |
| Argo CD | stable | GitOps CD |
| Keycloak | latest | Identity Management |
| Code-Server | latest | Browser VS Code |

## Troubleshooting

**Cloud image already exists:**
```bash
./deploy.sh --skip-image-download
```

**Cilium not ready:**
```bash
kubectl -n kube-system get pods -l k8s-app=cilium
```

**LoadBalancer IP not reachable:**
```bash
kubectl get ciliumloadbalancerippool  # For Cilium
kubectl get ipaddresspool -n metallb-system  # For MetalLB
```
