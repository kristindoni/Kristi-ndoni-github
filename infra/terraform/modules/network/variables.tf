variable "name_prefix" {
  description = "Prefix used for all network resource names."
  type        = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "vnet_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "subnet_cidrs" {
  description = "CIDR blocks for each subnet."
  type = object({
    appgw = string
    web   = string
    api   = string
    db    = string
  })
  default = {
    appgw = "10.20.0.0/24"
    web   = "10.20.1.0/24"
    api   = "10.20.2.0/24"
    db    = "10.20.3.0/24"
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
