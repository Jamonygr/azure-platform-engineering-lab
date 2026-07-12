variable "environment_id" {
  description = "Immutable UUIDv7 generated and inventoried before any external resource is created."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", lower(var.environment_id)))
    error_message = "environment_id must be a lowercase-compatible UUIDv7."
  }
}

variable "environment_name" {
  description = "Developer-selected lowercase environment slug."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}[a-z0-9]$", var.environment_name))
    error_message = "environment_name must be a 3-20 character lowercase slug."
  }
}

variable "location" {
  description = "Approved Azure deployment region."
  type        = string
  default     = "westeurope"

  validation {
    condition     = contains(["westeurope", "northeurope", "germanywestcentral"], lower(var.location))
    error_message = "location is outside the tested EU allowlist."
  }
}

variable "owner" {
  description = "Requester login used for ownership and cleanup authorization."
  type        = string

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner cannot be empty."
  }
}

variable "expires_at" {
  description = "RFC3339 UTC expiration controlled by the lifecycle inventory."
  type        = string

  validation {
    condition     = can(formatdate("YYYY-MM-DD'T'hh:mm:ss'Z'", var.expires_at))
    error_message = "expires_at must be an RFC3339 timestamp."
  }
}

variable "create_resource_group" {
  description = "Create the environment resource group. ADE adapters set this false."
  type        = bool
  default     = true
}

variable "resource_group_name" {
  description = "Existing ADE-created resource group name when create_resource_group is false."
  type        = string
  default     = null

  validation {
    condition     = var.create_resource_group || (var.resource_group_name != null && length(var.resource_group_name) > 0)
    error_message = "resource_group_name is required when create_resource_group is false."
  }
}

variable "provisioning_channel" {
  description = "Provisioning adapter. GitHub creates an OIDC deployment identity; ADE uses its project identity."
  type        = string
  default     = "github"

  validation {
    condition     = contains(["github", "ade"], var.provisioning_channel)
    error_message = "provisioning_channel must be github or ade."
  }
}

variable "github_owner" {
  description = "Owner of the generated repository; required for GitHub provisioning."
  type        = string
  default     = null
}

variable "github_repository" {
  description = "Generated repository name; required for GitHub provisioning."
  type        = string
  default     = null

  validation {
    condition     = var.provisioning_channel != "github" || (var.github_owner != null && var.github_repository != null)
    error_message = "github_owner and github_repository are required for the GitHub channel."
  }
}

variable "log_analytics_workspace_id" {
  description = "Shared Log Analytics workspace resource ID."
  type        = string
}

variable "action_group_id" {
  description = "Central action group resource ID."
  type        = string
}

variable "platform_admin_email" {
  description = "Budget notification recipient."
  type        = string
}

variable "policy_definition_ids" {
  description = "Platform policy definition IDs keyed by the platform output names."
  type        = map(string)
  default     = {}
}

variable "policy_effect" {
  description = "Assignment effect for policies that expose an effect parameter."
  type        = string
  default     = "Audit"

  validation {
    condition     = contains(["Audit", "Deny", "Disabled"], var.policy_effect)
    error_message = "policy_effect must be Audit, Deny, or Disabled."
  }
}

variable "budget_amount" {
  description = "Monthly cost-alert amount in the subscription billing currency. Budgets do not stop resources."
  type        = number
  default     = 10

  validation {
    condition     = var.budget_amount > 0
    error_message = "budget_amount must be positive."
  }
}

variable "budget_start_date" {
  description = "Optional first day of a month in RFC3339 form. Defaults to the plan month."
  type        = string
  default     = null
}

variable "tags" {
  description = "Additional non-sensitive workload tags. Reserved platform tags take precedence."
  type        = map(string)
  default     = {}
}
