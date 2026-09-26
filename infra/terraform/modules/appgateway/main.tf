# Single internet-facing entry point (Application Gateway v2 + WAF) that
# publishes BOTH tiers to the internet via path-based routing:
#   /api/*  -> API tier backend pool
#   /*      -> web tier backend pool
# This keeps one public IP/hostname to front with the CDN while still
# satisfying "both web and API tiers exposed to the internet".

resource "azurerm_public_ip" "appgw" {
  name                = "${var.name_prefix}-appgw-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  # Free Azure-provided hostname (<label>.<region>.cloudapp.azure.com) - a
  # bare IP can never get a valid TLS cert, and isn't durable/brandable.
  # A custom domain would CNAME onto this same FQDN.
  domain_name_label = var.dns_label
  tags               = var.tags
}

locals {
  tls_enabled = var.tls_certificate_key_vault_secret_id != ""
}

# Only created when a cert is actually supplied - App Gateway's Key Vault
# integration needs a user-assigned identity (system-assigned isn't
# supported for this), so there's no point standing one up otherwise.
resource "azurerm_user_assigned_identity" "appgw" {
  count               = local.tls_enabled ? 1 : 0
  name                = "${var.name_prefix}-appgw-identity"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_role_assignment" "appgw_kv_secrets_user" {
  count                = local.tls_enabled ? 1 : 0
  scope                = var.tls_key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.appgw[0].principal_id
}

resource "azurerm_web_application_firewall_policy" "this" {
  name                = "${var.name_prefix}-waf-policy"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  policy_settings {
    enabled = true
    mode    = "Prevention"
  }

  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }
  }
}

resource "azurerm_application_gateway" "this" {
  name                = "${var.name_prefix}-appgw"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  sku {
    name = "WAF_v2"
    tier = "WAF_v2"
  }

  dynamic "identity" {
    for_each = local.tls_enabled ? [1] : []
    content {
      type         = "UserAssigned"
      identity_ids = [azurerm_user_assigned_identity.appgw[0].id]
    }
  }

  # The provider's implicit default TLS policy (AppGwSslPolicy20150501) is
  # now rejected by Azure as deprecated - pin an explicit modern policy.
  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }

  # Scales the gateway itself out under load; separate from VMSS autoscale.
  autoscale_configuration {
    min_capacity = 2
    max_capacity = 10
  }

  firewall_policy_id = azurerm_web_application_firewall_policy.this.id

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = var.subnet_id
  }

  frontend_ip_configuration {
    name                 = "appgw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  # Private frontend so the web tier can reach the api tier over the VNet
  # instead of hairpinning back out through the public internet/WAF.
  # WAF_v2/Standard_v2 requires Static allocation for a private frontend IP
  # (Dynamic is rejected), which in turn requires an explicit address.
  frontend_ip_configuration {
    name                          = "appgw-internal-ip"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.internal_frontend_ip
  }

  frontend_port {
    name = "port-80"
    port = 80
  }

  dynamic "frontend_port" {
    for_each = local.tls_enabled ? [1] : []
    content {
      name = "port-443"
      port = 443
    }
  }

  dynamic "ssl_certificate" {
    for_each = local.tls_enabled ? [1] : []
    content {
      name                = "appgw-tls-cert"
      key_vault_secret_id = var.tls_certificate_key_vault_secret_id
    }
  }

  backend_address_pool {
    name = "web-pool"
  }

  backend_address_pool {
    name = "api-pool"
  }

  probe {
    name                = "web-probe"
    protocol            = "Http"
    path                = "/"
    host                = "127.0.0.1"
    interval            = 15
    timeout             = 10
    unhealthy_threshold = 3
  }

  probe {
    name                = "api-probe"
    protocol            = "Http"
    path                = "/api/status"
    host                = "127.0.0.1"
    interval            = 15
    timeout             = 10
    unhealthy_threshold = 3
  }

  backend_http_settings {
    name                  = "web-http-settings"
    cookie_based_affinity = "Disabled"
    port                  = var.container_port
    protocol              = "Http"
    request_timeout       = 30
    probe_name            = "web-probe"
  }

  backend_http_settings {
    name                  = "api-http-settings"
    cookie_based_affinity = "Disabled"
    port                  = var.container_port
    protocol              = "Http"
    request_timeout       = 30
    probe_name            = "api-probe"
  }

  http_listener {
    name                           = "public-listener"
    frontend_ip_configuration_name = "appgw-frontend-ip"
    frontend_port_name             = "port-80"
    protocol                       = "Http"
  }

  http_listener {
    name                           = "internal-listener"
    frontend_ip_configuration_name = "appgw-internal-ip"
    frontend_port_name             = "port-80"
    protocol                       = "Http"
  }

  dynamic "http_listener" {
    for_each = local.tls_enabled ? [1] : []
    content {
      name                           = "public-listener-https"
      frontend_ip_configuration_name = "appgw-frontend-ip"
      frontend_port_name             = "port-443"
      protocol                       = "Https"
      ssl_certificate_name           = "appgw-tls-cert"
    }
  }

  url_path_map {
    name                               = "path-routing"
    default_backend_address_pool_name  = "web-pool"
    default_backend_http_settings_name = "web-http-settings"

    path_rule {
      name                       = "api-rule"
      paths                      = ["/api/*"]
      backend_address_pool_name  = "api-pool"
      backend_http_settings_name = "api-http-settings"
    }
  }

  # Once TLS is on, plain HTTP on the public listener just redirects to
  # HTTPS - except for the ACME HTTP-01 challenge path, which has to stay
  # on plain HTTP or certificate renewal breaks.
  dynamic "url_path_map" {
    for_each = local.tls_enabled ? [1] : []
    content {
      name                              = "http-redirect"
      default_redirect_configuration_name = "http-to-https"

      path_rule {
        name                       = "acme-challenge"
        paths                      = ["/.well-known/acme-challenge/*"]
        backend_address_pool_name  = "web-pool"
        backend_http_settings_name = "web-http-settings"
      }
    }
  }

  dynamic "redirect_configuration" {
    for_each = local.tls_enabled ? [1] : []
    content {
      name                 = "http-to-https"
      redirect_type        = "Permanent"
      target_listener_name = "public-listener-https"
      include_path         = true
      include_query_string = true
    }
  }

  request_routing_rule {
    name               = "public-routing-rule"
    rule_type          = "PathBasedRouting"
    http_listener_name = "public-listener"
    url_path_map_name  = local.tls_enabled ? "http-redirect" : "path-routing"
    priority           = 100
  }

  dynamic "request_routing_rule" {
    for_each = local.tls_enabled ? [1] : []
    content {
      name               = "public-routing-rule-https"
      rule_type          = "PathBasedRouting"
      http_listener_name = "public-listener-https"
      url_path_map_name  = "path-routing"
      priority           = 105
    }
  }

  # Same path-based rules, reachable only from inside the VNet - this is
  # what the web tier's API_HOST points at.
  request_routing_rule {
    name               = "internal-routing-rule"
    rule_type          = "PathBasedRouting"
    http_listener_name = "internal-listener"
    url_path_map_name  = "path-routing"
    priority           = 110
  }

  lifecycle {
    ignore_changes = [
      # VMSS module attaches instance NICs to these pools out-of-band;
      # don't let a plan revert that association.
      backend_address_pool,
    ]
  }
}
