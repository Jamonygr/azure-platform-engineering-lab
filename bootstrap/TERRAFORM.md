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
| [azapi_resource.table](https://registry.terraform.io/providers/Azure/azapi/2.10.0/docs/resources/resource) | resource |
| [azurerm_federated_identity_credential.github_platform](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/federated_identity_credential) | resource |
| [azurerm_resource_group.bootstrap](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/resource_group) | resource |
| [azurerm_role_assignment.state_blob_data](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.state_table_data](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.subscription_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.subscription_policy_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.subscription_user_access_administrator](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_storage_account.platform](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/storage_account) | resource |
| [azurerm_storage_account_queue_properties.platform](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/storage_account_queue_properties) | resource |
| [azurerm_storage_container.platform](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/storage_container) | resource |
| [azurerm_storage_management_policy.retention](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/storage_management_policy) | resource |
| [azurerm_user_assigned_identity.github_platform](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/user_assigned_identity) | resource |
| [azurerm_client_config.current](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/data-sources/client_config) | data source |
| [azurerm_subscription.current](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/data-sources/subscription) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_github_environment"></a> [github\_environment](#input\_github\_environment) | GitHub environment whose OIDC subject can administer the lab subscription. | `string` | `"platform-operations"` | no |
| <a name="input_github_owner"></a> [github\_owner](#input\_github\_owner) | GitHub account or organization that owns the platform repository. | `string` | n/a | yes |
| <a name="input_github_repository"></a> [github\_repository](#input\_github\_repository) | Name of the platform repository (without the owner). | `string` | n/a | yes |
| <a name="input_location"></a> [location](#input\_location) | Azure region for the durable platform state resources. | `string` | `"westeurope"` | no |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Resource group that permanently owns Terraform state and lifecycle inventory. | `string` | `"rg-platform-bootstrap"` | no |
| <a name="input_storage_account_name"></a> [storage\_account\_name](#input\_storage\_account\_name) | Globally unique storage account name, 3-24 lowercase alphanumeric characters. | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional tags applied to bootstrap resources. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_backend"></a> [backend](#output\_backend) | Values used by the azurerm backend configuration for platform state. |
| <a name="output_containers"></a> [containers](#output\_containers) | Private blob containers used for state, locks, evidence, and backups. |
| <a name="output_inventory_tables"></a> [inventory\_tables](#output\_inventory\_tables) | Authoritative lifecycle inventory table names. |
| <a name="output_platform_identity"></a> [platform\_identity](#output\_platform\_identity) | OIDC deployment identity identifiers; no credential is emitted. |
| <a name="output_storage_account_id"></a> [storage\_account\_id](#output\_storage\_account\_id) | ARM resource ID of the state and inventory storage account. |
<!-- END_TF_DOCS -->