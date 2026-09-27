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

output "principal_id" {
  description = <<-EOT
    Object ID of the GitHub Actions service principal. Add this to
    environments/prod's keyvault_admin_principal_ids (alongside your own
    signed-in-user object ID), it's what lets the pipeline's identity
    actually read secrets out of Key Vault at apply time, not just create
    resources. See docs/challenges.md for the chicken-and-egg this avoids.
  EOT
  value       = azuread_service_principal.github_actions.object_id
}
