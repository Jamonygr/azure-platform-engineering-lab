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
    modtm = {
      source  = "Azure/modtm"
      version = "= 0.4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "= 3.9.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "= 0.14.0"
    }
  }
}
