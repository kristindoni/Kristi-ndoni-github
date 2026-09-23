output "storage_account_name" {
  value = azurerm_storage_account.backups.name
}

output "storage_account_id" {
  value = azurerm_storage_account.backups.id
}

output "container_name" {
  value = azurerm_storage_container.db_backups.name
}
