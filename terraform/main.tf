provider "nutanix" {
  username     = var.user
  password     = var.password
  endpoint     = var.endpoint
  wait_timeout = 60
}

resource "nutanix_image" "bootstrap_image" {
  name        = "kairos-bootstrap-iso"
  source_path = "../bootstrap.iso"
}

data "nutanix_subnet" "vm_subnet" {
  subnet_name = var.subnet_name

  additional_filter {
    name = "cluster_reference.uuid"
    values = [data.nutanix_cluster.vm_cluster.id]
  }
}

data "nutanix_cluster" "vm_cluster" {
  name = var.cluster_name
}

resource "nutanix_virtual_machine" "kairos-bootstrap-iso-test" {
  name                   = "kairos-bootstrap-iso-test"
  num_vcpus_per_socket   = 4
  num_sockets            = 1
  memory_size_mib        = 8192
  boot_device_order_list = ["DISK", "CDROM"]
  boot_type = "UEFI"

  cluster_uuid = data.nutanix_cluster.vm_cluster.id

  nic_list {
    subnet_uuid = data.nutanix_subnet.vm_subnet.id
  }

  disk_list {
    data_source_reference = {
      kind = "image"
        uuid = nutanix_image.bootstrap_image.id
      }


    device_properties {
      disk_address = {
        device_index = 0
        adapter_type = "SATA"
      }

      device_type = "CDROM"
    }
  }

  disk_list {
    disk_size_mib   = 100000
    disk_size_bytes = 104857600000
  }
}

# Show IP address
output "ip_address" {
  value = nutanix_virtual_machine.kairos-bootstrap-iso-test.nic_list_status[0].ip_endpoint_list[0].ip
}
