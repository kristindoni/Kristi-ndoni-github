# Azure Front Door (Standard) sits in front of the Application Gateway and
# caches/distributes static content from Azure's global edge network based
# on client location, while still routing dynamic requests back to origin.

resource "azurerm_cdn_frontdoor_profile" "this" {
  name                = "${var.name_prefix}-afd"
  resource_group_name = var.resource_group_name
  sku_name            = "Standard_AzureFrontDoor"
  tags                = var.tags
}

resource "azurerm_cdn_frontdoor_endpoint" "this" {
  name                     = "${var.name_prefix}-afd-endpoint"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id
  tags                     = var.tags
}

resource "azurerm_cdn_frontdoor_origin_group" "this" {
  name                     = "${var.name_prefix}-origin-group"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id

  health_probe {
    path                = "/"
    protocol            = "Http"
    request_type        = "GET"
    interval_in_seconds = 30
  }

  load_balancing {
    sample_size                 = 4
    successful_samples_required = 3
  }
}

resource "azurerm_cdn_frontdoor_origin" "appgw" {
  name                          = "${var.name_prefix}-origin-appgw"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.this.id

  enabled                        = true
  host_name                      = var.origin_host_name
  http_port                      = 80
  https_port                     = 443
  origin_host_header             = var.origin_host_name
  priority                       = 1
  weight                         = 1000
  certificate_name_check_enabled = true
}

# Static assets (images/css) are cached and distributed at Azure's edge
# nodes closest to each client.
resource "azurerm_cdn_frontdoor_route" "static" {
  name                          = "${var.name_prefix}-route-static"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.this.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.this.id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.appgw.id]

  supported_protocols    = ["Http", "Https"]
  patterns_to_match      = ["/images/*", "/stylesheets/*"]
  forwarding_protocol    = "HttpOnly"
  link_to_default_domain = true
  https_redirect_enabled = false

  cache {
    query_string_caching_behavior = "IgnoreQueryString"
    compression_enabled           = true
    content_types_to_compress     = ["text/css", "application/javascript", "image/svg+xml"]
  }
}

# Everything else (server-rendered HTML, the API) is dynamic per request
# (timestamps/UUIDs) and must never be cached - always forwarded to origin.
resource "azurerm_cdn_frontdoor_route" "dynamic" {
  name                          = "${var.name_prefix}-route-dynamic"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.this.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.this.id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.appgw.id]

  supported_protocols    = ["Http", "Https"]
  patterns_to_match      = ["/*"]
  forwarding_protocol    = "HttpOnly"
  link_to_default_domain = true
  https_redirect_enabled = false
}
