locals {
  db_admin_login = "pgadmin"
}

resource "azurerm_resource_group" "this" {
  name     = "${var.name_prefix}-rg"
  location = var.location
  tags     = var.tags
}

module "network" {
  source              = "../../modules/network"
  name_prefix         = var.name_prefix
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

module "acr" {
  source              = "../../modules/acr"
  registry_name       = replace("${var.name_prefix}acr", "-", "")
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags
}

module "keyvault" {
  source              = "../../modules/keyvault"
  vault_name          = "${var.name_prefix}-kv"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  # NOTE: the api VMSS's own read access is granted by module.vmss_api
  # itself (key_vault_id input below) rather than wired here, to avoid a
  # keyvault <-> vmss_api circular module dependency.
  tags = var.tags
}

module "database" {
  source              = "../../modules/database"
  server_name         = "${var.name_prefix}-pg"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  db_subnet_id        = module.network.db_subnet_id
  private_dns_zone_id = module.network.postgres_private_dns_zone_id
  admin_login         = local.db_admin_login
  admin_password      = module.keyvault.db_admin_password
  tags                = var.tags
}

module "appgateway" {
  source              = "../../modules/appgateway"
  name_prefix         = var.name_prefix
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = module.network.appgw_subnet_id
  tags                = var.tags
}

module "monitoring" {
  source              = "../../modules/monitoring"
  name_prefix         = var.name_prefix
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  app_gateway_id      = module.appgateway.id
  postgres_server_id  = module.database.id
  tags                = var.tags
}

module "backup_storage" {
  source                          = "../../modules/storage-backup"
  name_prefix_storage             = var.backup_storage_account_name
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  principal_ids_with_write_access = [module.vmss_api.principal_id]
  tags                            = var.tags
}

module "cdn" {
  source              = "../../modules/cdn"
  name_prefix         = var.name_prefix
  resource_group_name = azurerm_resource_group.this.name
  origin_host_name    = module.appgateway.public_ip_address
  tags                = var.tags
}

module "vmss_web" {
  source               = "../../modules/vmss"
  name_prefix          = var.name_prefix
  tier                 = "web"
  location             = azurerm_resource_group.this.location
  resource_group_name  = azurerm_resource_group.this.name
  subnet_id            = module.network.web_subnet_id
  instances            = var.web_instances
  min_instances        = var.web_instances
  admin_ssh_public_key = var.admin_ssh_public_key
  acr_id               = module.acr.id
  acr_login_server     = module.acr.login_server
  image_name           = "web"
  image_tag            = var.web_image_tag
  container_env = {
    PORT = "3000"
    # Reaches the api tier over the VNet via the Application Gateway's
    # private frontend IP + the same /api/* path rule used publicly.
    API_HOST = "http://${module.appgateway.internal_ip_address}/api"
  }
  backend_address_pool_ids   = [module.appgateway.web_backend_pool_id]
  log_analytics_workspace_id = module.monitoring.workspace_id
  tags                       = var.tags
}

module "vmss_api" {
  source               = "../../modules/vmss"
  name_prefix          = var.name_prefix
  tier                 = "api"
  location             = azurerm_resource_group.this.location
  resource_group_name  = azurerm_resource_group.this.name
  subnet_id            = module.network.api_subnet_id
  instances            = var.api_instances
  min_instances        = var.api_instances
  admin_ssh_public_key = var.admin_ssh_public_key
  acr_id               = module.acr.id
  acr_login_server     = module.acr.login_server
  image_name           = "api"
  image_tag            = var.api_image_tag
  container_env = {
    PORT   = "3000"
    DBUSER = local.db_admin_login
    DB     = module.database.database_name
    DBHOST = module.database.fqdn
    DBPORT = "5432"
  }
  db_password_secret_uri     = "${module.keyvault.vault_uri}secrets/db-admin-password"
  enable_key_vault_access    = true
  key_vault_id               = module.keyvault.id
  backend_address_pool_ids   = [module.appgateway.api_backend_pool_id]
  log_analytics_workspace_id = module.monitoring.workspace_id
  tags                       = var.tags
}

resource "azurerm_monitor_data_collection_rule_association" "web" {
  name                    = "${var.name_prefix}-dcr-assoc-web"
  target_resource_id      = module.vmss_web.id
  data_collection_rule_id = module.monitoring.data_collection_rule_id
}

resource "azurerm_monitor_data_collection_rule_association" "api" {
  name                    = "${var.name_prefix}-dcr-assoc-api"
  target_resource_id      = module.vmss_api.id
  data_collection_rule_id = module.monitoring.data_collection_rule_id
}
