# 1. DATA SOURCES

# Fetch the existing VCN from the OCI-HPC project
data "oci_core_vcn" "hpc_network" {
  vcn_id = var.existing_vcn_id
}

# Discover existing HPC instances to act as Quobyte clients
data "oci_core_instances" "hpc_nodes" {
  compartment_id = var.compartment_ocid
  state          = "RUNNING"
}

# Get VNIC Attachments for all discovered HPC nodes
data "oci_core_vnic_attachments" "hpc_vnic_attachments" {
  count          = length(data.oci_core_instances.hpc_nodes.instances)
  compartment_id = var.compartment_ocid
  instance_id    = data.oci_core_instances.hpc_nodes.instances[count.index].id
}

# Get the actual VNIC details (where the IP lives)
data "oci_core_vnic" "hpc_vnics" {
  count   = length(data.oci_core_instances.hpc_nodes.instances)
  vnic_id = data.oci_core_vnic_attachments.hpc_vnic_attachments[count.index].vnic_attachments[0].vnic_id
}

# 2. MANAGED STORAGE NETWORK (Created within the existing HPC VCN)

data "oci_core_nat_gateways" "hpc_nat_gateways" {
  compartment_id = var.compartment_ocid
  vcn_id         = data.oci_core_vcn.hpc_network.id
}

# Create a custom Route Table for the Storage Subnet
resource "oci_core_route_table" "storage_subnet_route_table" {
  compartment_id = var.compartment_ocid
  vcn_id         = data.oci_core_vcn.hpc_network.id
  display_name   = "quobyte-storage-route-table"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = data.oci_core_nat_gateways.hpc_nat_gateways.nat_gateways[0].id
  }
}


resource "oci_core_subnet" "storage_subnet" {
  cidr_block = var.storage_subnet_cidr
  compartment_id    = var.compartment_ocid
  # availability_domain = var.ad
  vcn_id            = data.oci_core_vcn.hpc_network.id # Linked to fetched VCN
  security_list_ids = [oci_core_security_list.private_security_list.id]
  display_name      = "quobyte-storage-subnet"
  prohibit_public_ip_on_vnic = true

  # Use the existing VCN's default route table
  route_table_id    = oci_core_route_table.storage_subnet_route_table.id

  dns_label = var.storage_subnet_dns_name
}

resource "oci_core_security_list" "private_security_list" {
  compartment_id = var.compartment_ocid
  vcn_id         = data.oci_core_vcn.hpc_network.id
  display_name   = "qb-cluster-private-security-list"

  ingress_security_rules {
    protocol    = "all"
    source      = data.oci_core_vcn.hpc_network.cidr_block
    description = "Allow all traffic from the entire HPC VCN"
  }

  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 22
      max = 22
    }
    description = "Allow SSH access"
  }

  ingress_security_rules {
    protocol    = "1" # ICMP
    source      = data.oci_core_vcn.hpc_network.cidr_block
    description = "Allow internal PING"
    icmp_options {
      type = 8
      code = 0
    }
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    description = "Allow all traffic to Quobyte storage nodes"
  }
}

# 3. QUOBYTE SERVER INSTANCES
resource "tls_private_key" "internal_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

locals {
  quobyte_node_configs = {
    "arm" = {
      shape = "VM.Standard.A1.Flex", ocpus = 4, memory = 24, nvmes = 0, is_flex = true
    },
    "x86_dense" = {
      shape = "VM.DenseIO.E5.Flex", ocpus = 16, memory = 192, nvmes = 2, is_flex = true
    },
    "x86_bm" = {
      shape = "BM.DenseIO.E5.128", is_flex = false
    },
    "gpu" = {
      shape = "VM.GPU.A10.1", ocpus = 15, memory = 240, nvmes = 0, is_flex = false
    }
  }
  quobyte_node_cfg = local.quobyte_node_configs[var.quobyte_node_type]

  cloud_init_script = <<-EOT
    #!/bin/bash
    echo 'ACTION=="add|change", KERNEL=="sd[cdefgh]", ATTR{queue/rotational}="0"' > /etc/udev/rules.d/60-block-storage-rotational.rules
    udevadm control --reload-rules
    udevadm trigger
  EOT
}

resource "oci_core_instance" "quobyte_node" {
  count          = var.quobyte_instance_count
  compartment_id = var.compartment_ocid
  availability_domain = var.ad
  display_name   = "quobyte-server-${count.index + 1}"
  shape          = local.quobyte_node_cfg.shape

  dynamic "shape_config" {
    for_each = local.quobyte_node_cfg.is_flex ? [1] : []
    content {
      ocpus         = local.quobyte_node_cfg.ocpus
      memory_in_gbs = local.quobyte_node_cfg.memory
      nvmes         = local.quobyte_node_cfg.nvmes > 0 ? local.quobyte_node_cfg.nvmes : null
    }
  }

  create_vnic_details {
    subnet_id              = oci_core_subnet.storage_subnet.id
    hostname_label         = "quobyte-server-${count.index + 1}"
    assign_public_ip       = false
  }

  source_details {
    source_type = "image"
    source_id   = var.quobyte_image_ocid
  }

  metadata = {
    ssh_authorized_keys = tls_private_key.internal_key.public_key_openssh
    user_data           = base64encode(local.cloud_init_script)
  }

  agent_config {
    are_all_plugins_disabled = false
    is_management_disabled   = true
    is_monitoring_disabled   = true
    plugins_config {
      desired_state = "ENABLED"
      name          = "Block Volume Management"
    }
  }
}

# 4. BLOCK VOLUME RESOURCES
resource "oci_core_volume" "data_ssd_disk_1" {
  count          = length(oci_core_instance.quobyte_node)
  compartment_id = var.compartment_ocid
  availability_domain = oci_core_instance.quobyte_node[count.index].availability_domain
  size_in_gbs    = 512
  display_name   = "quobyte-data-ssd-vol-${count.index + 1}-a"
  vpus_per_gb    = 20
}

resource "oci_core_volume" "data_ssd_disk_2" {
  count          = length(oci_core_instance.quobyte_node)
  compartment_id = var.compartment_ocid
  availability_domain = oci_core_instance.quobyte_node[count.index].availability_domain
  size_in_gbs    = 512
  display_name   = "quobyte-data-ssd-vol-${count.index + 1}-b"
  vpus_per_gb    = 20
}

resource "oci_core_volume" "data_hdd_disk" {
  count          = length(oci_core_instance.quobyte_node)
  compartment_id = var.compartment_ocid
  availability_domain = oci_core_instance.quobyte_node[count.index].availability_domain
  size_in_gbs    = 2048
  display_name   = "quobyte-data-hdd-vol-${count.index + 1}"
  vpus_per_gb    = 0
}

resource "oci_core_volume" "metadata_disk" {
  count          = length(oci_core_instance.quobyte_node)
  compartment_id = var.compartment_ocid
  availability_domain = oci_core_instance.quobyte_node[count.index].availability_domain
  size_in_gbs    = 250
  display_name   = "quobyte-metadata-vol-${count.index + 1}"
  vpus_per_gb    = 20
}

# 5. VOLUME ATTACHMENTS
resource "oci_core_volume_attachment" "d_ssd_attachment_1" {
  count          = length(oci_core_instance.quobyte_node)
  attachment_type = var.volume_attachment_type
  instance_id    = oci_core_instance.quobyte_node[count.index].id
  volume_id      = oci_core_volume.data_ssd_disk_1[count.index].id
  is_agent_auto_iscsi_login_enabled = var.volume_attachment_type == "iscsi" ? true : null
  depends_on    = [oci_core_volume_attachment.m_attachment]
}

resource "oci_core_volume_attachment" "d_ssd_attachment_2" {
  count          = length(oci_core_instance.quobyte_node)
  attachment_type = var.volume_attachment_type
  instance_id    = oci_core_instance.quobyte_node[count.index].id
  volume_id      = oci_core_volume.data_ssd_disk_2[count.index].id
  is_agent_auto_iscsi_login_enabled = var.volume_attachment_type == "iscsi" ? true : null
  depends_on    = [oci_core_volume_attachment.m_attachment]
}

resource "oci_core_volume_attachment" "d_hdd_attachment" {
  count          = length(oci_core_instance.quobyte_node)
  attachment_type = var.volume_attachment_type
  instance_id    = oci_core_instance.quobyte_node[count.index].id
  volume_id      = oci_core_volume.data_hdd_disk[count.index].id
  is_agent_auto_iscsi_login_enabled = var.volume_attachment_type == "iscsi" ? true : null
}

resource "oci_core_volume_attachment" "m_attachment" {
  count          = length(oci_core_instance.quobyte_node)
  attachment_type = var.volume_attachment_type
  instance_id    = oci_core_instance.quobyte_node[count.index].id
  volume_id      = oci_core_volume.metadata_disk[count.index].id
  is_agent_auto_iscsi_login_enabled = var.volume_attachment_type == "iscsi" ? true : null
  depends_on    = [oci_core_volume_attachment.d_hdd_attachment]
}

# 6. DNS SETTINGS (Updated for existing VCN View)
data "oci_dns_views" "dns_views" {
  compartment_id = var.compartment_ocid
  scope          = "PRIVATE"
  display_name   = data.oci_core_vcn.hpc_network.display_name # Discovery from existing VCN
}

resource "oci_dns_zone" "dns_zone" {
  compartment_id = var.compartment_ocid
  name           = var.dns_zone_name
  zone_type      = "PRIMARY"
  scope          = "PRIVATE"
  view_id        = data.oci_dns_views.dns_views.views[0].id
}


resource "oci_dns_rrset" "quobyte-s3subdomain" {
  zone_name_or_id = oci_dns_zone.dns_zone.id
  domain          = "*.s3.${var.dns_zone_name}"
  rtype           = "A"
  dynamic "items" {
    for_each = oci_core_instance.quobyte_node
    iterator = target
    content {
      domain = "*.s3.${var.dns_zone_name}"
      rtype  = "A"
      rdata  = target.value["private_ip"]
      ttl    = 60
    }
  }
  view_id = data.oci_dns_views.dns_views.views[0].id
}

resource "oci_dns_rrset" "quobyte-s3" {
  zone_name_or_id = oci_dns_zone.dns_zone.id
  domain          = "s3.${var.dns_zone_name}"
  rtype           = "A"
  dynamic "items" {
    for_each = oci_core_instance.quobyte_node
    iterator = target
    content {
      domain = "s3.${var.dns_zone_name}"
      rtype  = "A"
      rdata  = target.value["private_ip"]
      ttl    = 60
    }
  }
  view_id = data.oci_dns_views.dns_views.views[0].id
}

resource "oci_dns_rrset" "quobyte-api" {
  zone_name_or_id = oci_dns_zone.dns_zone.id
  domain          = "api.${var.dns_zone_name}"
  rtype           = "A"
  items {
      domain = "api.${var.dns_zone_name}"
      rtype  = "A"
      rdata  = oci_core_instance.quobyte_node[0].private_ip
      ttl    = 60
  }
  view_id = data.oci_dns_views.dns_views.views[0].id
}

resource "oci_dns_rrset" "quobyte-console" {
  zone_name_or_id = oci_dns_zone.dns_zone.id
  domain          = "console.${var.dns_zone_name}"
  rtype           = "A"
  items {
      domain = "console.${var.dns_zone_name}"
      rtype  = "A"
      rdata  = oci_core_instance.quobyte_node[0].private_ip
      ttl    = 60
  }
  view_id = data.oci_dns_views.dns_views.views[0].id
}

// Create registry handle DNS record
resource "oci_dns_rrset" "quobyte-registry-handle" {
  zone_name_or_id = oci_dns_zone.dns_zone.id
  domain          = "registry.${var.dns_zone_name}"
  rtype           = "A"
  dynamic "items" {
    for_each = slice(oci_core_instance.quobyte_node[*],
                     0,
                     min(3, length(oci_core_instance.quobyte_node)))
    iterator = target
    content {
      domain = "registry.${var.dns_zone_name}"
      rtype  = "A"
      rdata  = target.value["private_ip"]
      ttl    = 60
    }
  }
  view_id = data.oci_dns_views.dns_views.views[0].id
  depends_on = [ oci_core_instance.quobyte_node ]
}

// Sleepto give OCI DNS time to propagate the record
resource "time_sleep" "dns_wait" {
  depends_on = [oci_dns_rrset.quobyte-registry-handle]
  create_duration = "120s"
}


// ---- Objects Storage bucket for tiering
data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.compartment_ocid
}

# Fetch the specific instance selected by the user
data "oci_core_instance" "selected_controller" {
  instance_id = var.controller_ocid
}

# Fetch the VNIC attachments to get the IP addresses
data "oci_core_vnic_attachments" "controller_vnics" {
  compartment_id = var.compartment_ocid
  instance_id    = var.controller_ocid
}

# Fetch the actual VNIC details
data "oci_core_vnic" "controller_vnic" {
  vnic_id = data.oci_core_vnic_attachments.controller_vnics.vnic_attachments[0].vnic_id
}

resource "null_resource" "run_ansible_on_controller" {
  # This ensures the files are copied/run only after the inventory is generated
  # and the Quobyte nodes are fully provisioned.
depends_on = [
    oci_core_instance.quobyte_node,
    oci_core_volume_attachment.m_attachment,
    local_file.ansible_inventory,
    local_file.ansible_vars,
    time_sleep.dns_wait
  ]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = data.oci_core_vnic.controller_vnic.public_ip_address
    private_key = var.ssh_private_key
  }

  # 1. Copy the entire ansible directory to the controller
  provisioner "file" {
    source      = "ansible"
    destination = "/home/ubuntu/ansible"
  }

  provisioner "file" {
    content     = tls_private_key.internal_key.private_key_pem
    destination = "/home/ubuntu/.ssh/id_rsa_qb"
  }

  # 2. Execute the playbook on the controller
  provisioner "remote-exec" {
    inline = [
      "chmod 0600 /home/ubuntu/.ssh/id_rsa_qb",
      "cd /home/ubuntu/ansible",
      "bash run_ansible.sh"
    ]
  }
}
