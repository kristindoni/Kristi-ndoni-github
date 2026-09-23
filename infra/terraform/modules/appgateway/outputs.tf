output "internal_ip_address" {
  value = one([for c in azurerm_application_gateway.this.frontend_ip_configuration : c.private_ip_address if c.name == "appgw-internal-ip"])
}

output "public_ip_address" {
  value = azurerm_public_ip.appgw.ip_address
}

output "public_fqdn" {
  value = azurerm_public_ip.appgw.fqdn
}

output "id" {
  value = azurerm_application_gateway.this.id
}

output "web_backend_pool_id" {
  value = one([for p in azurerm_application_gateway.this.backend_address_pool : p.id if p.name == "web-pool"])
}

output "api_backend_pool_id" {
  value = one([for p in azurerm_application_gateway.this.backend_address_pool : p.id if p.name == "api-pool"])
}
