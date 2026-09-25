# PostgreSQL Flexible Server, VNet-integrated only: it has no public endpoint
# at all, satisfying "DB tier should not be accessible from the Internet".

resource "azurerm_postgresql_flexible_server" "this" {
  name                = var.server_name
  resource_group_name = var.resource_group_name
  location            = var.location

  delegated_subnet_id          = var.db_subnet_id
  private_dns_zone_id          = var.private_dns_zone_id
  public_network_access_enabled = false

  administrator_login    = var.admin_login
  administrator_password = var.admin_password

  sku_name   = var.sku_name
  version    = "15"
  storage_mb = var.storage_mb

  backup_retention_days        = var.backup_retention_days
  geo_redundant_backup_enabled = var.geo_redundant_backup_enabled

  # Zone-redundant HA: a synchronous standby in a different AZ takes over
  # automatically on primary failure with no application-visible downtime
  # beyond a brief failover.
  dynamic "high_availability" {
    for_each = var.enable_high_availability ? [1] : []
    content {
      mode                      = "ZoneRedundant"
      standby_availability_zone = var.standby_availability_zone
    }
  }

  zone = var.primary_availability_zone

  tags = var.tags

  lifecycle {
    ignore_changes = [zone] # avoid disruptive replace on transient zone drift
  }
}

resource "azurerm_postgresql_flexible_server_database" "app" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# Keep the server patched automatically outside business hours.
resource "azurerm_postgresql_flexible_server_configuration" "log_checkpoints" {
  name      = "log_checkpoints"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "on"
}
