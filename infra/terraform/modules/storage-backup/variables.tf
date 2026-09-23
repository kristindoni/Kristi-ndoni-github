variable "name_prefix_storage" {
  description = "Storage account name: lowercase alphanumeric only, <= 24 chars, globally unique."
  type        = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "principal_ids_with_write_access" {
  description = "Principals (e.g. the API VMSS managed identity) allowed to write backup blobs."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
