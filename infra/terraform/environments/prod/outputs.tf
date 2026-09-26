output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "app_public_url" {
  description = "Public entry point (Application Gateway). The CDN endpoint below is the client-facing, geo-distributed URL."
  # coalesce() guards against a plan-time null: the provider doesn't always
  # mark fqdn as "known after apply" when only domain_name_label changes on
  # an existing public IP.
  value = "${var.tls_certificate_key_vault_secret_id != "" ? "https" : "http"}://${coalesce(module.appgateway.public_fqdn, module.appgateway.public_ip_address)}"
}

output "cdn_endpoint_hostname" {
  value = var.enable_cdn ? module.cdn[0].endpoint_hostname : "CDN disabled (enable_cdn = false)"
}

output "acr_login_server" {
  value = module.acr.login_server
}

output "postgres_fqdn" {
  value = module.database.fqdn
}

output "log_analytics_workspace_id" {
  value = module.monitoring.workspace_id
}

output "backup_storage_account_name" {
  value = module.backup_storage.storage_account_name
}

output "key_vault_uri" {
  value = module.keyvault.vault_uri
}
