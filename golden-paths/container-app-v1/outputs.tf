locals {
  tracked_resource_ids = concat([
    local.resource_group_id,
    module.managed_environment.resource_id,
    "${module.managed_environment.resource_id}/providers/Microsoft.Insights/diagnosticSettings/diag-cae-${var.environment_name}-${local.short_id}",
    module.container_app.resource_id,
    azurerm_user_assigned_identity.runtime.id,
    azurerm_role_assignment.runtime_acr_reader.id,
    azurerm_consumption_budget_resource_group.environment.id,
    azurerm_monitor_activity_log_alert.administrative_failure.id,
    ],
    var.provisioning_channel == "github" ? [
      azurerm_user_assigned_identity.deployment[0].id,
      azurerm_federated_identity_credential.deployment[0].id,
      azurerm_role_assignment.deployment_app[0].id,
      azurerm_role_assignment.deployment_acr_writer[0].id,
    ] : [],
    [for assignment in azurerm_resource_group_policy_assignment.platform : assignment.id]
  )
}

output "endpoint" {
  description = "Trusted public Container Apps HTTPS endpoint."
  value       = module.container_app.fqdn_url
}

output "resource_group_names" {
  description = "All disposable resource groups tracked before cleanup."
  value       = [local.resource_group_name]
}

output "resource_ids" {
  description = "Disposable resource inventory; the shared ACR is intentionally excluded."
  value       = local.tracked_resource_ids
}

output "image_repository" {
  description = "Exact ABAC-scoped repository that cleanup deletes after Terraform destroy."
  value       = var.image_repository
}

output "shared_acr_id" {
  description = "Immutable shared registry ID paired with image_repository for fail-closed cleanup."
  value       = var.shared_acr_id
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
    golden_path          = "container-app"
    path_version         = "v1"
    provisioning_channel = var.provisioning_channel
    resource_group_names = [local.resource_group_name]
    resource_ids         = local.tracked_resource_ids
    endpoint             = module.container_app.fqdn_url
    image_repository     = var.image_repository
    shared_acr_id        = var.shared_acr_id
    budget_amount        = var.budget_amount
    expires_at           = var.expires_at
  }
}
