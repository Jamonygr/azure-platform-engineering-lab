locals {
  tracked_resource_ids = concat([
    local.resource_group_id,
    module.aks.resource_id,
    "${module.aks.resource_id}/providers/Microsoft.Insights/diagnosticSettings/diag-aks-${var.environment_name}-${local.short_id}",
    module.aks.node_resource_group_id,
    azapi_update_resource.node_resource_group_tags.resource_id,
    azurerm_role_assignment.developer_cluster_user.id,
    azurerm_role_assignment.developer_rbac_writer.id,
    azurerm_role_assignment.kubelet_acr_reader.id,
    azurerm_consumption_budget_resource_group.environment.id,
    azurerm_consumption_budget_resource_group.nodes.id,
    azurerm_monitor_activity_log_alert.administrative_failure.id,
    ],
    var.provisioning_channel == "github" ? [
      azurerm_user_assigned_identity.deployment[0].id,
      azurerm_federated_identity_credential.deployment[0].id,
      azurerm_role_assignment.deployment_cluster_user[0].id,
      azurerm_role_assignment.deployment_rbac_writer[0].id,
      azurerm_role_assignment.deployment_acr_writer[0].id,
    ] : [],
    [for assignment in azurerm_resource_group_policy_assignment.platform : assignment.id],
    [for assignment in azurerm_resource_group_policy_assignment.node_platform : assignment.id],
    [for assignment in azurerm_resource_policy_assignment.kubernetes_guardrail : assignment.id]
  )
}

output "endpoint" {
  description = "Application endpoint is discovered after Helm deploy and default-domain enablement."
  value       = ""
}

output "endpoint_strategy" {
  description = "Controller instruction for resolving the post-deployment HTTPS endpoint."
  value       = "aks-managed-default-domain"
}

output "cluster_name" {
  description = "AKS cluster name used by the approved deployment workflow."
  value       = module.aks.name
}

output "resource_group_names" {
  description = "Primary and AKS-managed node resource groups that cleanup must verify absent."
  value       = [local.resource_group_name, module.aks.node_resource_group_name]
}

output "node_resource_group" {
  description = "Explicit node resource group tracked as a first-class disposable resource."
  value       = module.aks.node_resource_group_name
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

output "oidc_issuer_url" {
  description = "AKS workload identity issuer for application service accounts."
  value       = module.aks.oidc_issuer_profile_issuer_url
}

output "state_contract" {
  description = "Sanitizable lifecycle inventory contract persisted by the controller."
  value = {
    environment_id       = lower(var.environment_id)
    golden_path          = "aks"
    path_version         = "v1"
    provisioning_channel = var.provisioning_channel
    resource_group_names = [local.resource_group_name, module.aks.node_resource_group_name]
    resource_ids         = local.tracked_resource_ids
    endpoint             = ""
    endpoint_strategy    = "aks-managed-default-domain"
    image_repository     = var.image_repository
    shared_acr_id        = var.shared_acr_id
    budget_amount        = var.budget_amount
    expires_at           = var.expires_at
  }
}
