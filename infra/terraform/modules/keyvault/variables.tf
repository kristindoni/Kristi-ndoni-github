variable "vault_name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
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
