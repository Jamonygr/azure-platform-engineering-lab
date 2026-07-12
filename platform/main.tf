data "azurerm_subscription" "current" {}

locals {
  acr_name = substr("${var.name_prefix}${var.unique_suffix}acr", 0, 50)
  workload_locations = {
    westeurope         = "weu"
    northeurope        = "neu"
    germanywestcentral = "gwc"
  }
  tags = merge(var.tags, {
    "platform.component" = "shared"
    "platform.lab"       = "azure-platform-engineering-lab"
    "platform.managed"   = "terraform"
  })

  policy_documents = {
    required_platform_tags       = jsondecode(file("${path.module}/../policies/definitions/required-platform-tags.json"))
    allowed_eu_locations         = jsondecode(file("${path.module}/../policies/definitions/allowed-eu-locations.json"))
    app_service_https_only       = jsondecode(file("${path.module}/../policies/definitions/app-service-https-only.json"))
    container_app_secure_ingress = jsondecode(file("${path.module}/../policies/definitions/container-app-secure-ingress.json"))
  }

  lifecycle_github_environments = toset([
    "lifecycle",
    "aks-approval",
    "destructive-operations",
  ])

  apps_repository_contributor_condition = <<-CONDITION
    (
      !(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/content/read'})
      OR @Request[Microsoft.ContainerRegistry/registries/repositories:name] StringStartsWithIgnoreCase 'apps/'
    )
    AND
    (
      !(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/content/write'})
      OR @Request[Microsoft.ContainerRegistry/registries/repositories:name] StringStartsWithIgnoreCase 'apps/'
    )
    AND
    (
      !(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/content/delete'})
      OR @Request[Microsoft.ContainerRegistry/registries/repositories:name] StringStartsWithIgnoreCase 'apps/'
    )
    AND
    (
      !(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/metadata/read'})
      OR @Request[Microsoft.ContainerRegistry/registries/repositories:name] StringStartsWithIgnoreCase 'apps/'
    )
    AND
    (
      !(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/metadata/write'})
      OR @Request[Microsoft.ContainerRegistry/registries/repositories:name] StringStartsWithIgnoreCase 'apps/'
    )
    AND
    (
      !(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/metadata/delete'})
      OR @Request[Microsoft.ContainerRegistry/registries/repositories:name] StringStartsWithIgnoreCase 'apps/'
    )
  CONDITION
}

resource "azurerm_resource_group" "platform" {
  name     = var.resource_group_name
  location = lower(var.location)
  tags     = local.tags
}

resource "azurerm_log_analytics_workspace" "platform" {
  for_each = local.workload_locations

  name                       = "law-${var.name_prefix}-${var.unique_suffix}-${each.value}"
  location                   = each.key
  resource_group_name        = azurerm_resource_group.platform.name
  sku                        = "PerGB2018"
  retention_in_days          = var.log_retention_days
  internet_ingestion_enabled = true
  internet_query_enabled     = true
  tags                       = local.tags
}

resource "azurerm_container_registry" "platform" {
  name                          = local.acr_name
  resource_group_name           = azurerm_resource_group.platform.name
  location                      = azurerm_resource_group.platform.location
  sku                           = "Standard"
  admin_enabled                 = false
  anonymous_pull_enabled        = false
  data_endpoint_enabled         = false
  public_network_access_enabled = true
  tags                          = local.tags
}

# AzureRM 4.80.0 does not expose ACR's roleAssignmentMode. Keep the AVM-style
# AzureRM resource for the stable surface and use AzAPI only for this gap.
resource "azapi_update_resource" "acr_abac" {
  type        = "Microsoft.ContainerRegistry/registries@2025-11-01"
  resource_id = azurerm_container_registry.platform.id
  body = {
    properties = {
      roleAssignmentMode = "AbacRepositoryPermissions"
    }
  }
}

resource "azurerm_monitor_diagnostic_setting" "acr" {
  name                       = "send-to-platform-law"
  target_resource_id         = azurerm_container_registry.platform.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.platform[lower(var.location)].id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_action_group" "platform" {
  name                = "ag-platform-operations"
  resource_group_name = azurerm_resource_group.platform.name
  short_name          = "platops"
  tags                = local.tags

  email_receiver {
    name                    = "platform-admin"
    email_address           = var.platform_admin_email
    use_common_alert_schema = true
  }
}

resource "azurerm_user_assigned_identity" "lifecycle" {
  name                = "uami-platform-lifecycle"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "lifecycle" {
  for_each = local.lifecycle_github_environments

  name                      = "github-${each.value}"
  user_assigned_identity_id = azurerm_user_assigned_identity.lifecycle.id
  issuer                    = "https://token.actions.githubusercontent.com"
  audience                  = ["api://AzureADTokenExchange"]
  subject                   = "repo:${var.github_owner}/${var.github_repository}:environment:${each.value}"
}

resource "azurerm_role_assignment" "lifecycle_contributor" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.lifecycle.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "lifecycle_user_access" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "User Access Administrator"
  principal_id         = azurerm_user_assigned_identity.lifecycle.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "lifecycle_blob_data" {
  scope                = var.bootstrap_storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.lifecycle.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "lifecycle_table_data" {
  scope                = var.bootstrap_storage_account_id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azurerm_user_assigned_identity.lifecycle.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "lifecycle_acr_catalog" {
  scope                = azurerm_container_registry.platform.id
  role_definition_name = "Container Registry Repository Catalog Lister"
  principal_id         = azurerm_user_assigned_identity.lifecycle.principal_id
  principal_type       = "ServicePrincipal"

  depends_on = [azapi_update_resource.acr_abac]
}

resource "azurerm_role_assignment" "lifecycle_acr_repository" {
  scope                = azurerm_container_registry.platform.id
  role_definition_name = "Container Registry Repository Contributor"
  principal_id         = azurerm_user_assigned_identity.lifecycle.principal_id
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition            = local.apps_repository_contributor_condition

  depends_on = [azapi_update_resource.acr_abac]
}

resource "azurerm_policy_definition" "platform" {
  for_each = { for key, document in local.policy_documents : key => document if var.enable_policy_definitions }

  name         = "pelab-${replace(each.key, "_", "-")}"
  policy_type  = "Custom"
  mode         = each.value.properties.mode
  display_name = each.value.properties.displayName
  description  = each.value.properties.description
  metadata     = jsonencode(each.value.properties.metadata)
  parameters   = jsonencode(each.value.properties.parameters)
  policy_rule  = jsonencode(each.value.properties.policyRule)
}
