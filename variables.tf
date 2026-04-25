# --- OCI Configuration ---

# variable "user_ocid" {}
# variable "fingerprint" {}
# variable "private_key_path" {}

variable "region" {
   description = "The region in which to deploy the Quobyte cluster, e.g. us-ashburn-1"
   type        = string
}
variable "ad" {
  description = "The OCID of the availability domain in which to deploy the Quobyte cluster"
  type        = string
}
variable "tenancy_ocid" {
  description = "The OCID of the tenant in which to deploy the Quobyte cluster"
  type        = string
}
variable "compartment_ocid" {
  description = "The OCID of the compartment in which to deploy the Quobyte cluster"
  type        = string
}

# --- HPC Integration Variables ---
variable "existing_vcn_id" {
  description = "The OCID of the existing VCN from the OCI-HPC deployment"
  type        = string
}

variable "controller_ocid" {
  description = "The OCID of the instance that will run the Ansible playbooks (usually the controller node)."
  type        = string
}

variable "ssh_private_key" {
  description = "Private SSH key to log into controller node. Can be retrieved from OCI-HPC stack."
  type = string
}

# --- Quobyte Variables ---

variable "storage_subnet_cidr" {
  type        = string
  description = "Manual CIDR for the new storage subnet."
}

variable "quobyte_image_ocid" {
  description = "OCID of the OS image to use for the Quobyte nodes, must be ubuntu based"
  type        = string
}

variable "quobyte_admin_password" {
  description = "Password for the Quobyte admin user. WARNING: The password will be written to disk unecrypted."
  type        = string
  validation {
    condition     = can(regex("^\\S+$", var.quobyte_admin_password))
    error_message = "The admin password variable must not contain any spaces or tabs."
  }
}

variable "quobyte_admin_email" {
  description = "Email address for the Quobyte admin user"
}

variable "quobyte_license_key" {
  description = "Quobyte license key, leave empty for the Quobyte Free Edition"
  default     = ""
}

variable "quobyte_instance_count" {
  description = "Number of Quobyte server instances in the cluster"
  type        = number
  validation {
    condition     = var.quobyte_instance_count >= 1
    error_message = "The 'quobyte_instance_count' must be at least 1"
  }
}

variable "quobyte_node_type" {
  description = "Architecture profile: arm, x86_dense, x86_bm, or gpu"
  type        = string
  validation {
    condition     = contains(["arm", "x86_dense", "gpu", "x86_bm"], var.quobyte_node_type)
    error_message = "Invalid quobyte_node_type. You must choose one of: arm, x86_dense, x86_bm, or gpu."
  }
}

variable "arm_ocpus" {
  type    = string
  default = "4"
}

variable "dense_nvmes" {
  type    = string
  default = "2"
}

variable "volume_attachment_type" {
  type        = string
  default     = "iscsi"
  description = "The type of volume attachment. Options: paravirtualized, iscsi"
  validation {
    condition     = contains(["paravirtualized", "iscsi"], var.volume_attachment_type)
    error_message = "The attachment type must be either 'paravirtualized' or 'iscsi'."
  }
}

variable "storage_subnet_dns_name" {
  description = "subdomain for the storage subnet"
  default     = "quobyte"
}

variable "dns_zone_name" {
  description = "DNS prefix for the cluster's service like S3 and webconsole"
  default     = "quobyte-oci.internal"
}

variable "enable_tiering" {
  type    = bool
  description = "Enables the setup of an external object storage bucket for tiering from Quobyte"
  default = false
}

variable "s3_access_key" {
  type    = string
  default = ""
}

variable "s3_secret_key" {
  type    = string
  default = ""
  sensitive = true
}

variable "bucket_name" {
  type        = string
  description = "The name of the Object Storage bucket for Quobyte tiering (must exist)."
  default     = ""
}
