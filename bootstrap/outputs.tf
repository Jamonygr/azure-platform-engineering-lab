output "backend" {
  description = "Values used by the azurerm backend configuration for platform state."
  value = {
    resource_group_name  = azurerm_resource_group.bootstrap.name
    storage_account_name = azurerm_storage_account.platform.name
    container_name       = azurerm_storage_container.platform["tfstate"].name
    key                  = "platform/platform.tfstate"
    use_azuread_auth     = true
    use_oidc             = true
    client_id            = azurerm_user_assigned_identity.github_platform.client_id
    tenant_id            = data.azurerm_client_config.current.tenant_id
    subscription_id      = data.azurerm_client_config.current.subscription_id
  }
}

output "storage_account_id" {
  description = "ARM resource ID of the state and inventory storage account."
  value       = azurerm_storage_account.platform.id
}

output "platform_identity" {
  description = "OIDC deployment identity identifiers; no credential is emitted."
  value = {
    client_id    = azurerm_user_assigned_identity.github_platform.client_id
    principal_id = azurerm_user_assigned_identity.github_platform.principal_id
    tenant_id    = azurerm_user_assigned_identity.github_platform.tenant_id
    subject      = azurerm_federated_identity_credential.github_platform.subject
  }
}

output "inventory_tables" {
  description = "Authoritative lifecycle inventory table names."
  value       = sort(tolist(local.tables))
}

output "containers" {
  description = "Private blob containers used for state, locks, evidence, and backups."
  value       = sort(tolist(local.containers))
}
