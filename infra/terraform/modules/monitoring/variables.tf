variable "name_prefix" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "retention_in_days" {
  type    = number
  default = 90
}

variable "app_gateway_id" {
  type = string
}

variable "postgres_server_id" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
