terraform {
  required_version = "= 1.15.8"

  backend "azurerm" {}

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "= 2.10.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "= 3.9.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 4.80.0"
    }
  }
}

provider "azapi" {}

provider "azuread" {}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }

  storage_use_azuread = true
}
