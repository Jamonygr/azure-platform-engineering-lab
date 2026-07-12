data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {}

locals {
  containers = toset(["tfstate", "locks", "evidence", "statebackup"])
  tables     = toset(["PlatformEnvironments", "PlatformResources", "PlatformOperations", "PlatformEvidence"])
  tags = merge(var.tags, {
    "platform.component" = "bootstrap"
    "platform.lab"       = "azure-platform-engineering-lab"
    "platform.managed"   = "terraform"
  })
}

resource "azurerm_resource_group" "bootstrap" {
  name     = var.resource_group_name
  location = lower(var.location)
  tags     = local.tags
}

# The lab uses GitHub-hosted runners with nondeterministic egress addresses.
# Authentication is Entra/OIDC only (shared keys are disabled), every container
# is private, and production private networking is explicitly out of scope.
#trivy:ignore:AVD-AZU-0012
resource "azurerm_storage_account" "platform" {
  name                              = var.storage_account_name
  resource_group_name               = azurerm_resource_group.bootstrap.name
  location                          = azurerm_resource_group.bootstrap.location
  account_tier                      = "Standard"
  account_replication_type          = "LRS"
  account_kind                      = "StorageV2"
  min_tls_version                   = "TLS1_2"
  shared_access_key_enabled         = false
  default_to_oauth_authentication   = true
  public_network_access_enabled     = true
  allow_nested_items_to_be_public   = false
  infrastructure_encryption_enabled = true
  tags                              = local.tags

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 7
    }

    container_delete_retention_policy {
      days = 7
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_account_queue_properties" "platform" {
  storage_account_id = azurerm_storage_account.platform.id

  logging {
    delete                = true
    read                  = true
    version               = "1.0"
    write                 = true
    retention_policy_days = 7
  }
}

resource "azurerm_storage_container" "platform" {
  for_each = local.containers

  name                  = each.value
  storage_account_id    = azurerm_storage_account.platform.id
  container_access_type = "private"
}

# Keep current Terraform state durable while bounding recoverable history.
# Evidence blobs are sanitized controller artifacts; source archives and plan
# files are never written to this account by the lab workflows.
resource "azurerm_storage_management_policy" "retention" {
  storage_account_id = azurerm_storage_account.platform.id

  rule {
    name    = "terraform-state-history-seven-days"
    enabled = true

    filters {
      prefix_match = ["tfstate/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      version {
        delete_after_days_since_creation = 7
      }

      snapshot {
        delete_after_days_since_creation_greater_than = 7
      }
    }
  }

  rule {
    name    = "restricted-state-backups-seven-days"
    enabled = true

    filters {
      prefix_match = ["statebackup/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = 7
      }

      version {
        delete_after_days_since_creation = 7
      }

      snapshot {
        delete_after_days_since_creation_greater_than = 7
      }
    }
  }

  rule {
    name    = "sanitized-evidence-ninety-days"
    enabled = true

    filters {
      prefix_match = ["evidence/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = 90
      }

      version {
        delete_after_days_since_creation = 90
      }

      snapshot {
        delete_after_days_since_creation_greater_than = 90
      }
    }
  }
}

# Azure Tables are created over ARM so the storage account can keep Shared Key
# disabled. The lifecycle controller uses Entra ID and Table Data RBAC.
resource "azapi_resource" "table" {
  for_each = local.tables

  type      = "Microsoft.Storage/storageAccounts/tableServices/tables@2025-01-01"
  name      = each.value
  parent_id = "${azurerm_storage_account.platform.id}/tableServices/default"
  body      = {}
}

resource "azurerm_user_assigned_identity" "github_platform" {
  name                = "uami-github-platform"
  location            = azurerm_resource_group.bootstrap.location
  resource_group_name = azurerm_resource_group.bootstrap.name
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "github_platform" {
  name                      = "github-${var.github_environment}"
  user_assigned_identity_id = azurerm_user_assigned_identity.github_platform.id
  issuer                    = "https://token.actions.githubusercontent.com"
  audience                  = ["api://AzureADTokenExchange"]
  subject                   = "repo:${var.github_owner}/${var.github_repository}:environment:${var.github_environment}"
}

resource "azurerm_role_assignment" "subscription_contributor" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.github_platform.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "subscription_user_access_administrator" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "User Access Administrator"
  principal_id         = azurerm_user_assigned_identity.github_platform.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "subscription_policy_contributor" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Resource Policy Contributor"
  principal_id         = azurerm_user_assigned_identity.github_platform.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "state_blob_data" {
  scope                = azurerm_storage_account.platform.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.github_platform.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "state_table_data" {
  scope                = azurerm_storage_account.platform.id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azurerm_user_assigned_identity.github_platform.principal_id
  principal_type       = "ServicePrincipal"
}
