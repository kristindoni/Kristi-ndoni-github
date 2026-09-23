variable "name_prefix" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "origin_host_name" {
  description = "Public FQDN/IP of the Application Gateway to use as the CDN origin."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
