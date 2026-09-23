locals {
  vmss_name = "${var.name_prefix}-vmss-${var.tier}"
}

resource "azurerm_linux_virtual_machine_scale_set" "this" {
  name                = local.vmss_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.sku
  instances           = var.instances
  zones               = var.zones
  zone_balance        = true
  overprovision       = false
  admin_username      = var.admin_username
  tags                = var.tags

  # Base image is generic and stable across releases; only the container
  # image tag changes per deploy (see custom_data below), so we never need
  # to rebuild/re-bake a VM image for an app release.
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "StandardSSD_LRS"
    caching              = "ReadWrite"
  }

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  identity {
    type = "SystemAssigned"
  }

  network_interface {
    name    = "${local.vmss_name}-nic"
    primary = true

    ip_configuration {
      name                                         = "internal"
      primary                                      = true
      subnet_id                                    = var.subnet_id
      application_gateway_backend_address_pool_ids = var.backend_address_pool_ids
    }
  }

  custom_data = base64encode(templatefile("${path.module}/templates/cloud-init.tpl.yaml", {
    acr_login_server       = var.acr_login_server
    image_name             = var.image_name
    image_tag              = var.image_tag
    app_name               = var.tier
    container_port         = var.container_port
    container_env          = var.container_env
    db_password_secret_uri = var.db_password_secret_uri
  }))

  # Zero-downtime deploys: replace instances in small batches, only
  # proceeding once the previous batch reports healthy, and pause between
  # batches to let connections drain from the load balancer.
  upgrade_mode = "Rolling"

  rolling_upgrade_policy {
    max_batch_instance_percent              = 34
    max_unhealthy_instance_percent          = 34
    max_unhealthy_upgraded_instance_percent = 34
    pause_time_between_batches              = "PT1M"
  }

  # Required by upgrade_mode = Rolling: the platform needs a health signal
  # per instance to know when it's safe to move to the next batch.
  extension {
    name                       = "HealthExtension"
    publisher                  = "Microsoft.ManagedServices"
    type                       = "ApplicationHealthLinux"
    type_handler_version       = "1.0"
    auto_upgrade_minor_version = true
    settings = jsonencode({
      protocol    = "http"
      port        = var.container_port
      requestPath = var.tier == "api" ? "/api/status" : "/"
    })
  }

  extension {
    name                       = "AzureMonitorLinuxAgent"
    publisher                  = "Microsoft.Azure.Monitor"
    type                       = "AzureMonitorLinuxAgent"
    type_handler_version       = "1.0"
    auto_upgrade_minor_version = true
  }

  automatic_instance_repair {
    enabled      = true
    grace_period = "PT10M"
  }

  lifecycle {
    ignore_changes = [instances] # autoscale owns instance count after creation
  }
}

# Pull access to ACR via managed identity - no registry credentials anywhere.
resource "azurerm_role_assignment" "acr_pull" {
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_linux_virtual_machine_scale_set.this.identity[0].principal_id
}

resource "azurerm_role_assignment" "kv_secrets_user" {
  count                = var.key_vault_id != "" ? 1 : 0
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine_scale_set.this.identity[0].principal_id
}

# --- autoscale: handles load-driven scale-out and keeps a floor of
#     min_instances so a lost instance is always replaced -------------

resource "azurerm_monitor_autoscale_setting" "this" {
  name                = "${local.vmss_name}-autoscale"
  resource_group_name = var.resource_group_name
  location            = var.location
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.this.id
  tags                = var.tags

  profile {
    name = "default"

    capacity {
      default = var.instances
      minimum = var.min_instances
      maximum = var.max_instances
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.this.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 70
      }
      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.this.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 25
      }
      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT10M"
      }
    }
  }
}
