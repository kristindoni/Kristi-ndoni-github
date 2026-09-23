# Central observability: every tier's logs and metrics land here, never
# only on a host disk, so they survive an instance being replaced and are
# queryable/graphable in one place (Log Analytics + Azure Monitor Workbooks).

resource "azurerm_log_analytics_workspace" "this" {
  name                = "${var.name_prefix}-law"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = var.retention_in_days
  tags                = var.tags
}

# Ships syslog + the app's journald container logs from every VMSS instance
# (via the AzureMonitorLinuxAgent extension configured in the vmss module).
resource "azurerm_monitor_data_collection_rule" "vm_logs" {
  name                = "${var.name_prefix}-dcr-vm-logs"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.this.id
      name                  = "law-destination"
    }
  }

  data_flow {
    streams      = ["Microsoft-Syslog"]
    destinations = ["law-destination"]
  }

  data_sources {
    syslog {
      name           = "syslog-source"
      facility_names = ["*"]
      log_levels     = ["Info", "Warning", "Error", "Critical", "Emergency"]
      streams        = ["Microsoft-Syslog"]
    }
  }
}

resource "azurerm_monitor_diagnostic_setting" "appgw" {
  name                       = "${var.name_prefix}-appgw-diag"
  target_resource_id         = var.app_gateway_id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category = "ApplicationGatewayAccessLog"
  }

  enabled_log {
    category = "ApplicationGatewayFirewallLog"
  }

  metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "postgres" {
  name                       = "${var.name_prefix}-pg-diag"
  target_resource_id         = var.postgres_server_id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category = "PostgreSQLLogs"
  }

  metric {
    category = "AllMetrics"
  }
}

# Simple alert on API error rate / gateway unhealthy hosts to catch
# bottlenecks proactively rather than only via historical dashboards.
resource "azurerm_monitor_action_group" "ops" {
  name                = "${var.name_prefix}-ops-ag"
  resource_group_name = var.resource_group_name
  short_name          = "ops"
  tags                = var.tags
}

resource "azurerm_monitor_metric_alert" "appgw_unhealthy_hosts" {
  name                = "${var.name_prefix}-appgw-unhealthy-hosts"
  resource_group_name = var.resource_group_name
  scopes              = [var.app_gateway_id]
  description         = "Fires when the Application Gateway reports unhealthy backend hosts."
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.Network/applicationGateways"
    metric_name      = "UnhealthyHostCount"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 0
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}
