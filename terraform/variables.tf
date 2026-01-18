# Proxmox connection
variable "proxmox_host" {
  description = "Proxmox host address"
  type        = string
  default     = "192.168.40.10"
}

variable "proxmox_user" {
  description = "Proxmox API user"
  type        = string
  default     = "root@pam"
}

variable "proxmox_password" {
  description = "Proxmox password"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Proxmox node name"
  type        = string
  default     = "pve"
}

# VM configuration
variable "vm_count" {
  description = "Number of VMs to create"
  type        = number
  default     = 3
}

variable "vm_name_prefix" {
  description = "Prefix for VM names"
  type        = string
  default     = "k8s"
}

variable "vm_id_start" {
  description = "Starting VM ID"
  type        = number
  default     = 200
}

variable "vm_memory" {
  description = "Memory in MB"
  type        = number
  default     = 4096
}

variable "vm_cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 2
}

variable "vm_disk_size" {
  description = "Disk size (e.g., 32G)"
  type        = string
  default     = "32G"
}

variable "vm_storage" {
  description = "Storage pool for VM disks"
  type        = string
  default     = "speedy-nvme-drive"
}

variable "vm_network_bridge" {
  description = "Network bridge"
  type        = string
  default     = "vmbr0"
}

# Cloud-init configuration
variable "ci_user" {
  description = "Cloud-init user"
  type        = string
  default     = "rocky"
}

variable "ci_password" {
  description = "Cloud-init password"
  type        = string
  sensitive   = true
  default     = "changeme123"
}

variable "ssh_public_key" {
  description = "SSH public key for cloud-init"
  type        = string
}

# Rocky Linux cloud image
variable "rocky_image_url" {
  description = "URL for Rocky Linux cloud image"
  type        = string
  default     = "https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2"
}

variable "template_vmid" {
  description = "VM ID for the cloud-init template"
  type        = number
  default     = 9000
}

variable "ceph_disk_size" {
  description = "Size of the Ceph OSD disk in GB"
  type        = number
  default     = 20
}
