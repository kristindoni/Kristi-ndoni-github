# Object storage for logical (pg_dump) database backups. This is a
# supplement to PostgreSQL Flexible Server's built-in automated backups
# (module.database, backup_retention_days) - defense in depth in case of
# accidental data corruption/deletion that PITR alone wouldn't recover from
# as conveniently, and a portable export format if we ever migrate engines.

resource "azurerm_storage_account" "backups" {
  name                            = var.name_prefix_storage
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "GRS" # geo-redundant: survives a regional outage
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                            = var.tags

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }
    container_delete_retention_policy {
      days = 30
    }
  }
}

resource "azurerm_storage_container" "db_backups" {
  name                  = "db-backups"
  storage_account_name  = azurerm_storage_account.backups.name
  container_access_type = "private"
}

resource "azurerm_storage_management_policy" "lifecycle" {
  storage_account_id = azurerm_storage_account.backups.id

  rule {
    name    = "age-out-old-backups"
    enabled = true

    filters {
      prefix_match = ["${azurerm_storage_container.db_backups.name}/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than    = 30
        tier_to_archive_after_days_since_modification_greater_than = 90
        delete_after_days_since_modification_greater_than          = 365
      }
    }
  }
}

resource "azurerm_role_assignment" "writers" {
  for_each             = toset(var.principal_ids_with_write_access)
  scope                = azurerm_storage_account.backups.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = each.value
}
