# Download Rocky Linux cloud image
resource "proxmox_virtual_environment_download_file" "rocky_cloud_image" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = var.proxmox_node
  url          = var.rocky_image_url
  file_name    = "rocky-9-cloud.img"
  overwrite    = false
}

# Create VMs
resource "proxmox_virtual_environment_vm" "k8s_node" {
  count     = var.vm_count
  name      = count.index == 0 ? "${var.vm_name_prefix}-master" : "${var.vm_name_prefix}-worker-${count.index}"
  node_name = var.proxmox_node
  vm_id     = var.vm_id_start + count.index

  # Don't start automatically - we'll start after cloud-init is configured
  started = true

  # Basic VM settings
  machine = "q35"
  bios    = "seabios"

  agent {
    enabled = true
  }

  cpu {
    cores = var.vm_cores
    type  = "host"
  }

  memory {
    dedicated = var.vm_memory
  }

  # OS disk from cloud image
  disk {
    datastore_id = var.vm_storage
    file_id      = proxmox_virtual_environment_download_file.rocky_cloud_image.id
    interface    = "scsi0"
    size         = tonumber(replace(var.vm_disk_size, "G", ""))
    discard      = "on"
    ssd          = true
  }

  # Wait for cloud-init and QEMU agent
  lifecycle {
    ignore_changes = [
      disk[0].file_id,
    ]
  }

  # Ceph OSD disk (raw, unformatted)
  disk {
    datastore_id = var.vm_storage
    interface    = "scsi1"
    size         = var.ceph_disk_size
    discard      = "on"
    ssd          = true
    file_format  = "raw"
  }

  # Network
  network_device {
    bridge = var.vm_network_bridge
    model  = "virtio"
  }

  # Cloud-init configuration
  initialization {
    datastore_id = var.vm_storage

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      username = var.ci_user
      password = var.ci_password
      keys     = [var.ssh_public_key]
    }
  }

  # SCSI controller
  scsi_hardware = "virtio-scsi-single"

  # Serial console for cloud-init
  serial_device {}

}

# Output the VM IPs (requires QEMU agent)
output "vm_ips" {
  description = "IP addresses of the created VMs"
  value = {
    for vm in proxmox_virtual_environment_vm.k8s_node :
    vm.name => try(vm.ipv4_addresses[1][0], "pending...")
  }
}

output "vm_names" {
  description = "Names of created VMs"
  value       = [for vm in proxmox_virtual_environment_vm.k8s_node : vm.name]
}

output "ssh_command" {
  description = "SSH command to connect to master"
  value       = "ssh ${var.ci_user}@${try(proxmox_virtual_environment_vm.k8s_node[0].ipv4_addresses[1][0], "pending")}"
}

# Generate Ansible inventory
resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/inventory.tftpl", {
    master_name = proxmox_virtual_environment_vm.k8s_node[0].name
    master_ip   = try(proxmox_virtual_environment_vm.k8s_node[0].ipv4_addresses[1][0], "pending")
    workers = [
      for i, vm in slice(proxmox_virtual_environment_vm.k8s_node, 1, length(proxmox_virtual_environment_vm.k8s_node)) : {
        name = vm.name
        ip   = try(vm.ipv4_addresses[1][0], "pending")
      }
    ]
  })
  filename = "${path.module}/../ansible/inventory.ini"
}
