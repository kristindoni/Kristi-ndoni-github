variable "name_prefix" {
  description = "Short prefix for all resource names, e.g. \"n3t-prod\"."
  type        = string
  default     = "n3t-prod"
}

variable "location" {
  type    = string
  default = "westeurope"
}

variable "admin_ssh_public_key" {
  description = "SSH public key installed on all VMSS instances (break-glass access; day-to-day operations go through the pipeline, not SSH)."
  type        = string
}

variable "web_image_tag" {
  description = "Container image tag to deploy for the web tier. Set per-deploy by CI."
  type        = string
  default     = "latest"
}

variable "api_image_tag" {
  description = "Container image tag to deploy for the api tier. Set per-deploy by CI."
  type        = string
  default     = "latest"
}

variable "web_instances" {
  type    = number
  default = 2
}

variable "api_instances" {
  type    = number
  default = 2
}

variable "backup_storage_account_name" {
  description = "Globally unique, lowercase alphanumeric, <= 24 chars."
  type        = string
}

variable "tags" {
  type = map(string)
  default = {
    project     = "node-3tier-app2"
    environment = "prod"
    managed_by  = "terraform"
  }
}
