terraform {
  required_version = "= 1.15.8"

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
