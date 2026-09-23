terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state so multiple pipeline runs / operators share a single
  # source of truth instead of local .tfstate files. The storage
  # account/container referenced here must exist before `terraform init`;
  # see infra/terraform/bootstrap/README.md for the one-time setup.
  backend "azurerm" {
    # Values supplied via `-backend-config` in CI (see .gitlab-ci.yml) so no
    # environment-specific values are hardcoded here:
    #   resource_group_name  = "<bootstrap RG>"
    #   storage_account_name = "<bootstrap storage account>"
    #   container_name       = "tfstate"
    #   key                  = "prod.terraform.tfstate"
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }
}
