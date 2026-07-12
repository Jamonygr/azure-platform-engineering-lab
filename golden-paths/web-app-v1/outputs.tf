locals {
  tracked_resource_ids = concat([
    local.resource_group_id,
    nonsensitive(module.service_plan.resource_id),
    nonsensitive(module.web_app.resource_id),
    nonsensitive("${module.web_app.resource_id}/providers/Microsoft.Insights/diagnosticSettings/diag-web-${var.environment_name}-${local.short_id}"),
    azurerm_application_insights.app.id,
    azurerm_user_assigned_identity.runtime.id,
    azurerm_consumption_budget_resource_group.environment.id,
    azurerm_monitor_metric_alert.http_5xx.id,
    ],
    var.provisioning_channel == "github" ? [
      azurerm_user_assigned_identity.deployment[0].id,
      azurerm_federated_identity_credential.deployment[0].id,
      azurerm_role_assignment.deployment[0].id,
    ] : [],
    [for assignment in azurerm_resource_group_policy_assignment.platform : assignment.id]
  )
}

output "endpoint" {
  description = "Trusted public HTTPS endpoint for the generated application repository."
  value       = "https://${module.web_app.resource_uri}"
}

output "resource_group_names" {
  description = "All disposable resource groups tracked before cleanup."
  value       = [local.resource_group_name]
}

output "resource_ids" {
  description = "Disposable ARM resource inventory; shared resources are intentionally absent."
  value       = local.tracked_resource_ids
}

output "deployment_client_id" {
  description = "Generated-repository OIDC client ID; null for ADE."
  value       = try(azurerm_user_assigned_identity.deployment[0].client_id, null)
}

output "deployment_principal_id" {
  description = "Generated-repository OIDC principal ID; null for ADE."
  value       = try(azurerm_user_assigned_identity.deployment[0].principal_id, null)
}

output "state_contract" {
  description = "Sanitizable lifecycle inventory contract persisted by the controller."
  value = {
    environment_id       = lower(var.environment_id)
    golden_path          = "web-app"
    path_version         = "v1"
    provisioning_channel = var.provisioning_channel
    resource_group_names = [local.resource_group_name]
    resource_ids         = local.tracked_resource_ids
    endpoint             = "https://${module.web_app.resource_uri}"
    image_repository     = null
    budget_amount        = var.budget_amount
    expires_at           = var.expires_at
  }
}
