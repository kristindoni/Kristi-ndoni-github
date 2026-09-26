data "azurerm_client_config" "current" {}

resource "azuread_application" "github_actions" {
  display_name = var.app_display_name
}

resource "azuread_service_principal" "github_actions" {
  client_id = azuread_application.github_actions.client_id
}

# One credential per trust boundary GitHub Actions runs jobs under. OIDC
# means no client secret is ever stored in either git provider - GitHub
# mints a short-lived token per run and Azure AD trusts it based on
# which of these subjects it was issued for.
resource "azuread_application_federated_identity_credential" "main_branch" {
  application_id = azuread_application.github_actions.id
  display_name   = "github-main-branch"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_repo}:ref:refs/heads/main"
}

resource "azuread_application_federated_identity_credential" "production_environment" {
  application_id = azuread_application.github_actions.id
  display_name   = "github-production-environment"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_repo}:environment:${var.production_environment_name}"
}

resource "azuread_application_federated_identity_credential" "pull_requests" {
  application_id = azuread_application.github_actions.id
  display_name   = "github-pull-requests"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_repo}:pull_request"
}

# Subscription-scoped, not resource-group-scoped: environments/prod's
# Terraform creates the resource group itself, so scoping this to that RG
# would mean the pipeline's identity can't exist until the RG exists,
# which can't exist until the pipeline runs. Owner (not just Contributor)
# because environments/prod also creates its own role assignments (VMSS
# -> ACR, VMSS -> Key Vault, etc.), which plain Contributor can't do.
resource "azurerm_role_assignment" "github_actions_owner" {
  scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name = "Owner"
  principal_id         = azuread_service_principal.github_actions.object_id
}
