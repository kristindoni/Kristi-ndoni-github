data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "this" {
  name                       = var.vault_name
  location                   = var.location
  resource_group_name        = var.resource_group_name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  enable_rbac_authorization  = true
  soft_delete_retention_days = 30
  purge_protection_enabled   = true
  tags                       = var.tags
}

# Explicit list of trusted operator/CI identities, NOT
# data.azurerm_client_config.current.object_id ("whoever happens to be
# running terraform right now"). That looked convenient with a single
# operator, but breaks the moment a second identity (e.g. a CI service
# principal) also needs to run terraform: it would try to swap this role
# assignment to the new principal, which needs Key Vault read access to
# even plan the swap - a real chicken-and-egg we hit switching to CI.
resource "azurerm_role_assignment" "admin" {
  for_each             = toset(var.admin_principal_ids)
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = each.value
}

# Any VMSS/managed identities that need read access to secrets at runtime.
resource "azurerm_role_assignment" "readers" {
  for_each             = toset(var.secret_reader_principal_ids)
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = each.value
}

resource "random_password" "db_admin" {
  length      = 24
  special     = true
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  min_special = 2
  # Postgres Flexible Server rejects a handful of punctuation characters.
  override_special = "-_.~"
}

resource "azurerm_key_vault_secret" "db_admin_password" {
  name         = "db-admin-password"
  value        = random_password.db_admin.result
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.admin]
}
