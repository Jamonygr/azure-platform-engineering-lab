variable "location" {
  description = "Azure region for the durable platform state resources."
  type        = string
  default     = "westeurope"

  validation {
    condition     = contains(["westeurope", "northeurope", "germanywestcentral"], lower(var.location))
    error_message = "location must be westeurope, northeurope, or germanywestcentral."
  }
}

variable "resource_group_name" {
  description = "Resource group that permanently owns Terraform state and lifecycle inventory."
  type        = string
  default     = "rg-platform-bootstrap"
}

variable "storage_account_name" {
  description = "Globally unique storage account name, 3-24 lowercase alphanumeric characters."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must contain 3-24 lowercase letters or digits."
  }
}

variable "github_owner" {
  description = "GitHub account or organization that owns the platform repository."
  type        = string
}

variable "github_repository" {
  description = "Name of the platform repository (without the owner)."
  type        = string
}

variable "github_environment" {
  description = "GitHub environment whose OIDC subject can administer the lab subscription."
  type        = string
  default     = "platform-operations"
}

variable "tags" {
  description = "Additional tags applied to bootstrap resources."
  type        = map(string)
  default     = {}
}
