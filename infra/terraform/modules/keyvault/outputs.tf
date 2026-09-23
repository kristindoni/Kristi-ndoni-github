output "id" {
  value = azurerm_key_vault.this.id
}

output "vault_uri" {
  value = azurerm_key_vault.this.vault_uri
}

output "db_admin_password" {
  value     = random_password.db_admin.result
  sensitive = true
}

output "db_admin_password_secret_id" {
  value = azurerm_key_vault_secret.db_admin_password.id
}
