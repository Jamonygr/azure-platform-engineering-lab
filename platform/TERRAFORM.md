<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | = 1.15.8 |
| <a name="requirement_azapi"></a> [azapi](#requirement\_azapi) | = 2.10.0 |
| <a name="requirement_azuread"></a> [azuread](#requirement\_azuread) | = 3.9.0 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | = 4.80.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azapi"></a> [azapi](#provider\_azapi) | 2.10.0 |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | 4.80.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [azapi_resource.ade_environment_type](https://registry.terraform.io/providers/Azure/azapi/2.10.0/docs/resources/resource) | resource |
| [azapi_resource.ade_project](https://registry.terraform.io/providers/Azure/azapi/2.10.0/docs/resources/resource) | resource |
| [azapi_resource.ade_project_environment_type](https://registry.terraform.io/providers/Azure/azapi/2.10.0/docs/resources/resource) | resource |
| [azapi_resource.devcenter](https://registry.terraform.io/providers/Azure/azapi/2.10.0/docs/resources/resource) | resource |
| [azapi_resource.lifecycle_dcr](https://registry.terraform.io/providers/Azure/azapi/2.10.0/docs/resources/resource) | resource |
| [azapi_resource.lifecycle_log_table](https://registry.terraform.io/providers/Azure/azapi/2.10.0/docs/resources/resource) | resource |
| [azapi_update_resource.acr_abac](https://registry.terraform.io/providers/Azure/azapi/2.10.0/docs/resources/update_resource) | resource |
| [azurerm_container_registry.platform](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/container_registry) | resource |
| [azurerm_federated_identity_credential.lifecycle](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/federated_identity_credential) | resource |
| [azurerm_log_analytics_workspace.platform](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/log_analytics_workspace) | resource |
| [azurerm_monitor_action_group.platform](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/monitor_action_group) | resource |
| [azurerm_monitor_diagnostic_setting.acr](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/monitor_diagnostic_setting) | resource |
| [azurerm_monitor_scheduled_query_rules_alert_v2.missing_reconciler_heartbeat](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/monitor_scheduled_query_rules_alert_v2) | resource |
| [azurerm_policy_definition.platform](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/policy_definition) | resource |
| [azurerm_resource_group.platform](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/resource_group) | resource |
| [azurerm_role_assignment.ade_acr_catalog](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.ade_apps_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.ade_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.ade_runner_reader](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.ade_user_access](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.ade_users](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.lifecycle_acr_catalog](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.lifecycle_acr_repository](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.lifecycle_ade_project_admin](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.lifecycle_blob_data](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.lifecycle_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.lifecycle_logs_ingestion](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.lifecycle_table_data](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.lifecycle_user_access](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_user_assigned_identity.ade_deployment](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/user_assigned_identity) | resource |
| [azurerm_user_assigned_identity.lifecycle](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/user_assigned_identity) | resource |
| [azurerm_subscription.current](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/data-sources/subscription) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_ade_runner_repository"></a> [ade\_runner\_repository](#input\_ade\_runner\_repository) | Private ACR repository that stores the digest-pinned ADE Terraform runner. | `string` | `"platform/ade-terraform"` | no |
| <a name="input_bootstrap_storage_account_id"></a> [bootstrap\_storage\_account\_id](#input\_bootstrap\_storage\_account\_id) | ARM ID of the bootstrap storage account containing inventory and evidence. | `string` | n/a | yes |
| <a name="input_developer_group_object_id"></a> [developer\_group\_object\_id](#input\_developer\_group\_object\_id) | Existing Entra group allowed to use the optional ADE project. Required when enable\_ade is true. | `string` | `null` | no |
| <a name="input_enable_ade"></a> [enable\_ade](#input\_enable\_ade) | Enable the optional Azure Deployment Environments maintenance-mode compatibility track. | `bool` | `false` | no |
| <a name="input_enable_policy_definitions"></a> [enable\_policy\_definitions](#input\_enable\_policy\_definitions) | Publish the lab custom policy definitions at subscription scope. | `bool` | `true` | no |
| <a name="input_github_owner"></a> [github\_owner](#input\_github\_owner) | GitHub owner of the platform repository. | `string` | n/a | yes |
| <a name="input_github_repository"></a> [github\_repository](#input\_github\_repository) | GitHub platform repository name. | `string` | n/a | yes |
| <a name="input_location"></a> [location](#input\_location) | Azure region for shared platform resources. | `string` | `"westeurope"` | no |
| <a name="input_log_retention_days"></a> [log\_retention\_days](#input\_log\_retention\_days) | Log Analytics interactive retention in days. | `number` | `30` | no |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Lowercase prefix used in globally unique shared-resource names. | `string` | `"pelab"` | no |
| <a name="input_platform_admin_email"></a> [platform\_admin\_email](#input\_platform\_admin\_email) | Address that receives platform, lifecycle, and cost alerts. | `string` | n/a | yes |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Resource group for resources shared by disposable environments. | `string` | `"rg-platform-shared"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional tags for shared resources. | `map(string)` | `{}` | no |
| <a name="input_unique_suffix"></a> [unique\_suffix](#input\_unique\_suffix) | Stable 4-10 character lowercase suffix used to make the ACR name globally unique. | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_action_group_id"></a> [action\_group\_id](#output\_action\_group\_id) | Central platform action group ID. |
| <a name="output_ade"></a> [ade](#output\_ade) | Optional ADE maintenance-mode compatibility resources. Null when disabled. |
| <a name="output_lifecycle_identity"></a> [lifecycle\_identity](#output\_lifecycle\_identity) | OIDC lifecycle identity identifiers. |
| <a name="output_lifecycle_log_ingestion"></a> [lifecycle\_log\_ingestion](#output\_lifecycle\_log\_ingestion) | OIDC-authenticated Azure Monitor Logs ingestion contract for lifecycle events. |
| <a name="output_log_analytics_workspace"></a> [log\_analytics\_workspace](#output\_log\_analytics\_workspace) | Primary shared monitoring workspace identifiers for platform lifecycle telemetry. |
| <a name="output_log_analytics_workspace_ids"></a> [log\_analytics\_workspace\_ids](#output\_log\_analytics\_workspace\_ids) | Location-keyed shared workspace IDs so every allowed AKS region has same-region Container Insights. |
| <a name="output_policy_definition_ids"></a> [policy\_definition\_ids](#output\_policy\_definition\_ids) | Policy IDs passed to disposable golden-path roots for RG-scoped assignments. |
| <a name="output_resource_group_id"></a> [resource\_group\_id](#output\_resource\_group\_id) | Shared platform resource group ID. |
| <a name="output_shared_acr"></a> [shared\_acr](#output\_shared\_acr) | Shared ABAC-mode registry consumed but never owned by workloads. |
<!-- END_TF_DOCS -->