variable "name_prefix" {
  type = string
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

variable "container_port" {
  type    = number
  default = 3000
}

variable "internal_frontend_ip" {
  description = "Static private IP for the internal listener, must fall inside the appgw subnet CIDR."
  type        = string
  default     = "10.20.0.10"
}

variable "tags" {
  type    = map(string)
  default = {}
}
