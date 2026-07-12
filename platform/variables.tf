variable "location" {
  description = "Azure region for shared platform resources."
  type        = string
  default     = "westeurope"

  validation {
    condition     = contains(["westeurope", "northeurope", "germanywestcentral"], lower(var.location))
    error_message = "location must be an approved EU region."
  }
}

variable "resource_group_name" {
  description = "Resource group for resources shared by disposable environments."
  type        = string
  default     = "rg-platform-shared"
}

variable "name_prefix" {
  description = "Lowercase prefix used in globally unique shared-resource names."
  type        = string
  default     = "pelab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,11}$", var.name_prefix))
    error_message = "name_prefix must contain 3-12 lowercase alphanumeric characters and begin with a letter."
  }
}

variable "unique_suffix" {
  description = "Stable 4-10 character lowercase suffix used to make the ACR name globally unique."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{4,10}$", var.unique_suffix))
    error_message = "unique_suffix must contain 4-10 lowercase letters or digits."
  }
}

variable "platform_admin_email" {
  description = "Address that receives platform, lifecycle, and cost alerts."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.platform_admin_email))
    error_message = "platform_admin_email must be a valid email address."
  }
}

variable "github_owner" {
  description = "GitHub owner of the platform repository."
  type        = string
}

variable "github_repository" {
  description = "GitHub platform repository name."
  type        = string
}

variable "bootstrap_storage_account_id" {
  description = "ARM ID of the bootstrap storage account containing inventory and evidence."
  type        = string
}

variable "enable_policy_definitions" {
  description = "Publish the lab custom policy definitions at subscription scope."
  type        = bool
  default     = true
}

variable "enable_ade" {
  description = "Enable the optional Azure Deployment Environments maintenance-mode compatibility track."
  type        = bool
  default     = false
}

variable "ade_runner_repository" {
  description = "Private ACR repository that stores the digest-pinned ADE Terraform runner."
  type        = string
  default     = "platform/ade-terraform"

  validation {
    condition     = can(regex("^[a-z0-9]+(?:[._/-][a-z0-9]+)*$", var.ade_runner_repository))
    error_message = "ade_runner_repository must be a lowercase ACR repository path."
  }
}

variable "developer_group_object_id" {
  description = "Existing Entra group allowed to use the optional ADE project. Required when enable_ade is true."
  type        = string
  default     = null

  validation {
    condition     = !var.enable_ade || (var.developer_group_object_id != null && can(regex("^[0-9a-fA-F-]{36}$", var.developer_group_object_id)))
    error_message = "developer_group_object_id must be a UUID when enable_ade is true."
  }
}

variable "log_retention_days" {
  description = "Log Analytics interactive retention in days."
  type        = number
  default     = 30

  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "log_retention_days must be between 30 and 730."
  }
}

variable "tags" {
  description = "Additional tags for shared resources."
  type        = map(string)
  default     = {}
}
