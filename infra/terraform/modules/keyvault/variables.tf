variable "vault_name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "admin_principal_ids" {
  description = "Principal IDs (operators + CI service principals) granted Key Vault Administrator. Must be explicit, not inferred from the caller, since more than one identity runs terraform against this vault."
  type        = list(string)
}

variable "secret_reader_principal_ids" {
  description = "Principal IDs (e.g. VMSS managed identities) allowed to read secrets."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
