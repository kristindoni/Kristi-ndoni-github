variable "server_name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "db_subnet_id" {
  type = string
}

variable "private_dns_zone_id" {
  type = string
}

variable "admin_login" {
  type    = string
  default = "pgadmin"
}

variable "admin_password" {
  type      = string
  sensitive = true
}

variable "sku_name" {
  description = "e.g. GP_Standard_D2s_v3"
  type        = string
  default     = "GP_Standard_D2s_v3"
}

variable "storage_mb" {
  type    = number
  default = 32768
}

variable "backup_retention_days" {
  type    = number
  default = 14
}

variable "geo_redundant_backup_enabled" {
  type    = bool
  default = true
}

variable "enable_high_availability" {
  type    = bool
  default = true
}

variable "primary_availability_zone" {
  type    = string
  default = "1"
}

variable "standby_availability_zone" {
  type    = string
  default = "2"
}

variable "database_name" {
  type    = string
  default = "appdb"
}

variable "tags" {
  type    = map(string)
  default = {}
}
