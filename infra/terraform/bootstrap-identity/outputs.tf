output "client_id" {
  description = "-> GitHub secret ARM_CLIENT_ID"
  value       = azuread_application.github_actions.client_id
}

output "tenant_id" {
  description = "-> GitHub secret ARM_TENANT_ID"
  value       = data.azurerm_client_config.current.tenant_id
}

output "subscription_id" {
  description = "-> GitHub secret ARM_SUBSCRIPTION_ID"
  value       = data.azurerm_client_config.current.subscription_id
}
