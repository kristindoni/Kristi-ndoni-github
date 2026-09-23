output "id" {
  value = azurerm_linux_virtual_machine_scale_set.this.id
}

output "name" {
  value = azurerm_linux_virtual_machine_scale_set.this.name
}

output "principal_id" {
  value = azurerm_linux_virtual_machine_scale_set.this.identity[0].principal_id
}
