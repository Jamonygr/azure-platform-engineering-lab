output "resource_group_id" {
  description = "Shared platform resource group ID."
  value       = azurerm_resource_group.platform.id
}

output "shared_acr" {
  description = "Shared ABAC-mode registry consumed but never owned by workloads."
  value = {
    id           = azurerm_container_registry.platform.id
    name         = azurerm_container_registry.platform.name
    login_server = azurerm_container_registry.platform.login_server
  }
}

output "log_analytics_workspace" {
  description = "Primary shared monitoring workspace identifiers for platform lifecycle telemetry."
  value = {
    id           = azurerm_log_analytics_workspace.platform[lower(var.location)].id
    workspace_id = azurerm_log_analytics_workspace.platform[lower(var.location)].workspace_id
  }
}

output "log_analytics_workspace_ids" {
  description = "Location-keyed shared workspace IDs so every allowed AKS region has same-region Container Insights."
  value       = { for location, workspace in azurerm_log_analytics_workspace.platform : location => workspace.id }
}

output "action_group_id" {
  description = "Central platform action group ID."
  value       = azurerm_monitor_action_group.platform.id
}

output "lifecycle_log_ingestion" {
  description = "OIDC-authenticated Azure Monitor Logs ingestion contract for lifecycle events."
  value = {
    endpoint     = azapi_resource.lifecycle_dcr.output.logs_ingestion_endpoint
    immutable_id = azapi_resource.lifecycle_dcr.output.immutable_id
    stream       = local.lifecycle_stream
    table        = local.lifecycle_table
  }
}

output "lifecycle_identity" {
  description = "OIDC lifecycle identity identifiers."
  value = {
    client_id    = azurerm_user_assigned_identity.lifecycle.client_id
    principal_id = azurerm_user_assigned_identity.lifecycle.principal_id
    tenant_id    = azurerm_user_assigned_identity.lifecycle.tenant_id
    subjects     = sort([for credential in azurerm_federated_identity_credential.lifecycle : credential.subject])
  }
}

output "policy_definition_ids" {
  description = "Policy IDs passed to disposable golden-path roots for RG-scoped assignments."
  value       = { for key, definition in azurerm_policy_definition.platform : key => definition.id }
}

output "ade" {
  description = "Optional ADE maintenance-mode compatibility resources. Null when disabled."
  value = var.enable_ade ? {
    devcenter_id               = azapi_resource.devcenter[0].id
    devcenter_name             = azapi_resource.devcenter[0].name
    project_id                 = azapi_resource.ade_project[0].id
    project_name               = azapi_resource.ade_project[0].name
    environment_type_id        = azapi_resource.ade_project_environment_type[0].id
    deployment_identity_id     = azurerm_user_assigned_identity.ade_deployment[0].id
    deployment_identity_client = azurerm_user_assigned_identity.ade_deployment[0].client_id
    runner_repository          = var.ade_runner_repository
  } : null
}
