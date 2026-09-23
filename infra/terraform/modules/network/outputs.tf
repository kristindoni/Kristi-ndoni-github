output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "appgw_subnet_id" {
  value = azurerm_subnet.appgw.id
}

output "web_subnet_id" {
  value = azurerm_subnet.web.id
}

output "api_subnet_id" {
  value = azurerm_subnet.api.id
}

output "db_subnet_id" {
  value = azurerm_subnet.db.id
}

output "postgres_private_dns_zone_id" {
  value = azurerm_private_dns_zone.postgres.id
}
