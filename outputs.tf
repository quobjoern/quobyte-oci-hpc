output "quobyte_node_private_ips" {
  value = [for instance in oci_core_instance.quobyte_node : instance.private_ip]
}

output "hpc_client_private_ips" {
  value = data.oci_core_vnic.hpc_vnics[*].private_ip_address
}

output "controller_public_ip" {
  value = data.oci_core_vnic.controller_vnic.public_ip_address
}

locals {
  inventory_content = <<-EOT
    [all:vars]
    ansible_ssh_common_args = '-o StrictHostKeyChecking=accept-new'

    [quobyte_servers]
    ${join("\n", [for instance in oci_core_instance.quobyte_node : "${instance.display_name} ansible_host=${instance.private_ip} ansible_user=ubuntu ansible_ssh_private_key_file=/home/ubuntu/.ssh/id_rsa_qb"])}

    [quobyte_clients]
    ${join("\n", [for index, inst in data.oci_core_instances.hpc_nodes.instances : "${inst.display_name} ansible_host=${data.oci_core_vnic.hpc_vnics[index].private_ip_address} ansible_user=ubuntu"])}
    EOT
}

resource "local_file" "ansible_inventory" {
  filename        = "ansible/inventory"
  content         = local.inventory_content
  file_permission = "0644"
}

locals {
  vars_content = <<-EOT
  ---
  # Variables for Quobyte setup
  quobyte_registry_handle: "registry.${var.dns_zone_name}"
  quobyte_s3_domain: "s3.${var.dns_zone_name}"
  cluster_domain: "cluster.${var.dns_zone_name}"
  storage_servers_subnet: "${oci_core_subnet.storage_subnet.cidr_block}"
  virtual_network_cidr: "${data.oci_core_vcn.hpc_network.cidr_block}"
  ${try(var.quobyte_license_key != "" ? "license_key: \"${var.quobyte_license_key}\"\n" : "", "")}
  admin_password: "${var.quobyte_admin_password}"
  admin_email: "${var.quobyte_admin_email}"
  # Optional S3 Tiering
  %{ if var.enable_tiering ~}
  s3_bucket_name: "${var.bucket_name}"
  s3_endpoint: "${data.oci_objectstorage_namespace.ns.namespace}.compat.objectstorage.${var.region}.oraclecloud.com"
  s3_access_key: "${var.s3_access_key}"
  s3_secret_key: "${var.s3_secret_key}"
  %{ endif ~}
  EOT
}

resource "local_file" "ansible_vars" {
  filename        = "ansible/ansible-vars.yaml"
  content         = local.vars_content
  file_permission = "0644"

  depends_on = [
    oci_dns_rrset.quobyte-registry-handle
  ]
}

output "z_next_step_run_ansible" {
  description = "Please add your compute, login and controller nodes to the ansible/inventory file. Then copy the anisble directory to your controller node, and run the following command on the controller node:"
  value = "(cd ansible && ansible-playbook -i inventory playbook.yaml)"
}
