# Separate state on purpose: this is the identity GitHub Actions uses to
# run terraform apply/destroy on environments/prod. If it lived in that
# same state, destroying environments/prod would also destroy the
# credentials needed to recreate it - exactly the chicken-and-egg problem
# this file exists to avoid. Apply this once per subscription; it should
# outlive any number of destroy/apply cycles of the main stack.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }

  backend "azurerm" {
    # Same remote state storage account as environments/prod, different
    # key so the two states never collide:
    #   resource_group_name  = "<bootstrap RG>"
    #   storage_account_name = "<bootstrap storage account>"
    #   container_name       = "tfstate"
    #   key                  = "bootstrap-identity.terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
}

provider "azuread" {}
