locals {
  ade_developer_role_definition_id = "4cbf0b6c-e750-441c-98a7-10da8387e4d6"
  ade_runner_reader_condition      = <<-CONDITION
    (
      !(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/content/read'})
      OR @Request[Microsoft.ContainerRegistry/registries/repositories:name] StringEqualsIgnoreCase '${var.ade_runner_repository}'
    )
    AND
    (
      !(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/metadata/read'})
      OR @Request[Microsoft.ContainerRegistry/registries/repositories:name] StringEqualsIgnoreCase '${var.ade_runner_repository}'
    )
  CONDITION
}

resource "azurerm_user_assigned_identity" "ade_deployment" {
  count = var.enable_ade ? 1 : 0

  name                = "uami-ade-deployment"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "ade_contributor" {
  count = var.enable_ade ? 1 : 0

  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.ade_deployment[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "ade_user_access" {
  count = var.enable_ade ? 1 : 0

  scope                = data.azurerm_subscription.current.id
  role_definition_name = "User Access Administrator"
  principal_id         = azurerm_user_assigned_identity.ade_deployment[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "ade_acr_catalog" {
  count = var.enable_ade ? 1 : 0

  scope                = azurerm_container_registry.platform.id
  role_definition_name = "Container Registry Repository Catalog Lister"
  principal_id         = azurerm_user_assigned_identity.ade_deployment[0].principal_id
  principal_type       = "ServicePrincipal"

  depends_on = [azapi_update_resource.acr_abac]
}

resource "azurerm_role_assignment" "ade_runner_reader" {
  count = var.enable_ade ? 1 : 0

  scope                = azurerm_container_registry.platform.id
  role_definition_name = "Container Registry Repository Reader"
  principal_id         = azurerm_user_assigned_identity.ade_deployment[0].principal_id
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition            = local.ade_runner_reader_condition

  depends_on = [azapi_update_resource.acr_abac]
}

resource "azurerm_role_assignment" "ade_apps_contributor" {
  count = var.enable_ade ? 1 : 0

  scope                = azurerm_container_registry.platform.id
  role_definition_name = "Container Registry Repository Contributor"
  principal_id         = azurerm_user_assigned_identity.ade_deployment[0].principal_id
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition            = local.apps_repository_contributor_condition

  depends_on = [azapi_update_resource.acr_abac]
}

resource "azapi_resource" "devcenter" {
  count = var.enable_ade ? 1 : 0

  type      = "Microsoft.DevCenter/devCenters@2025-02-01"
  name      = "dc-${var.name_prefix}-${var.unique_suffix}"
  parent_id = azurerm_resource_group.platform.id
  location  = azurerm_resource_group.platform.location
  tags      = local.tags
  body = {
    properties = {}
  }
}

resource "azapi_resource" "ade_environment_type" {
  count = var.enable_ade ? 1 : 0

  type      = "Microsoft.DevCenter/devCenters/environmentTypes@2025-02-01"
  name      = "sandbox"
  parent_id = azapi_resource.devcenter[0].id
  tags      = local.tags
  body = {
    properties = {
      displayName = "Sandbox (maintenance-mode compatibility)"
    }
  }
}

resource "azapi_resource" "ade_project" {
  count = var.enable_ade ? 1 : 0

  type      = "Microsoft.DevCenter/projects@2025-02-01"
  name      = "project-${var.name_prefix}-${var.unique_suffix}"
  parent_id = azurerm_resource_group.platform.id
  location  = azurerm_resource_group.platform.location
  tags      = local.tags
  body = {
    properties = {
      devCenterId = azapi_resource.devcenter[0].id
      description = "Optional ADE compatibility project; ADE is in maintenance mode."
    }
  }
}

resource "azapi_resource" "ade_project_environment_type" {
  count = var.enable_ade ? 1 : 0

  type      = "Microsoft.DevCenter/projects/environmentTypes@2025-02-01"
  name      = azapi_resource.ade_environment_type[0].name
  parent_id = azapi_resource.ade_project[0].id
  location  = azurerm_resource_group.platform.location
  tags      = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.ade_deployment[0].id]
  }

  body = {
    properties = {
      deploymentTargetId = data.azurerm_subscription.current.id
      displayName        = "Sandbox"
      status             = "Enabled"
      creatorRoleAssignment = {
        roles = {
          (local.ade_developer_role_definition_id) = {}
        }
      }
      userRoleAssignments = {
        (var.developer_group_object_id) = {
          roles = {
            (local.ade_developer_role_definition_id) = {}
          }
        }
      }
    }
  }
}

resource "azurerm_role_assignment" "ade_users" {
  count = var.enable_ade ? 1 : 0

  scope                = azapi_resource.ade_project[0].id
  role_definition_name = "Deployment Environments User"
  principal_id         = var.developer_group_object_id
  principal_type       = "Group"
}

# The OIDC janitor lists every project environment and sets/clamps native ADE
# expiration dates. Contributor is an ARM control-plane role and does not grant
# these Dev Center data actions, so assign the purpose-built project role.
resource "azurerm_role_assignment" "lifecycle_ade_project_admin" {
  count = var.enable_ade ? 1 : 0

  scope                = azapi_resource.ade_project[0].id
  role_definition_name = "DevCenter Project Admin"
  principal_id         = azurerm_user_assigned_identity.lifecycle.principal_id
  principal_type       = "ServicePrincipal"
}
