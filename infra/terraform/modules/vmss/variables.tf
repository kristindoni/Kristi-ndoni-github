variable "name_prefix" {
  type = string
}

variable "tier" {
  description = "Tier identifier, e.g. \"web\" or \"api\". Used in resource names."
  type        = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "sku" {
  type    = string
  default = "Standard_B2s"
}

variable "instances" {
  type    = number
  default = 2
}

variable "min_instances" {
  type    = number
  default = 2
}

variable "max_instances" {
  type    = number
  default = 6
}

variable "zones" {
  type    = list(string)
  default = ["1", "2", "3"]
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}

variable "admin_ssh_public_key" {
  type = string
}

# --- container / app config --------------------------------------------

variable "acr_id" {
  type = string
}

variable "acr_login_server" {
  type = string
}

variable "image_name" {
  type = string
}

variable "image_tag" {
  description = "Tag to deploy, e.g. a git SHA. Set by the CI pipeline."
  type        = string
  default     = "latest"
}

variable "container_port" {
  type    = number
  default = 3000
}

variable "container_env" {
  description = "Non-secret environment variables passed to the container."
  type        = map(string)
  default     = {}
}

variable "db_password_secret_uri" {
  description = "Key Vault secret URI (without ?api-version) for the DB password, fetched at container start. Empty string if not needed (e.g. web tier)."
  type        = string
  default     = ""
}

variable "enable_key_vault_access" {
  description = "Whether to grant this tier's managed identity Key Vault Secrets User on key_vault_id. Must be a literal true/false from the caller (not derived from key_vault_id, which is only known after apply)."
  type        = bool
  default     = false
}

variable "key_vault_id" {
  description = "Key Vault ID to grant this tier's identity read access to, if enable_key_vault_access is true."
  type        = string
  default     = ""
}

# --- backend integration --------------------------------------------------

variable "backend_address_pool_ids" {
  description = "Application Gateway backend pool IDs to associate this tier's NICs with."
  type        = list(string)
  default     = []
}

# --- monitoring -------------------------------------------------------

variable "log_analytics_workspace_id" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
