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
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | 4.80.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_container_app"></a> [container\_app](#module\_container\_app) | Azure/avm-res-app-containerapp/azurerm | 0.9.0 |
| <a name="module_managed_environment"></a> [managed\_environment](#module\_managed\_environment) | Azure/avm-res-app-managedenvironment/azurerm | 0.5.0 |

## Resources

| Name | Type |
|------|------|
| [azurerm_consumption_budget_resource_group.environment](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/consumption_budget_resource_group) | resource |
| [azurerm_federated_identity_credential.deployment](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/federated_identity_credential) | resource |
| [azurerm_monitor_activity_log_alert.administrative_failure](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/monitor_activity_log_alert) | resource |
| [azurerm_resource_group.environment](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/resource_group) | resource |
| [azurerm_resource_group_policy_assignment.platform](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/resource_group_policy_assignment) | resource |
| [azurerm_role_assignment.deployment_acr_writer](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.deployment_app](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.runtime_acr_reader](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_user_assigned_identity.deployment](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/user_assigned_identity) | resource |
| [azurerm_user_assigned_identity.runtime](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/user_assigned_identity) | resource |
| [azurerm_container_registry.shared](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/data-sources/container_registry) | data source |
| [azurerm_resource_group.environment](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/data-sources/resource_group) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_action_group_id"></a> [action\_group\_id](#input\_action\_group\_id) | Central action group resource ID. | `string` | n/a | yes |
| <a name="input_budget_amount"></a> [budget\_amount](#input\_budget\_amount) | Monthly alert amount in subscription currency; it does not stop consumption. | `number` | `15` | no |
| <a name="input_budget_start_date"></a> [budget\_start\_date](#input\_budget\_start\_date) | Optional first day of a month in RFC3339 form. | `string` | `null` | no |
| <a name="input_container_image"></a> [container\_image](#input\_container\_image) | Initial image. GitHub replaces this with an immutable digest after PLATFORM\_READY. | `string` | `"mcr.microsoft.com/azuredocs/containerapps-helloworld@sha256:e9b3e7c34664c7cffd7144864b0e4eec369bfde80068f9095dc63b37058bec48"` | no |
| <a name="input_create_resource_group"></a> [create\_resource\_group](#input\_create\_resource\_group) | Create the environment resource group. ADE adapters set this false. | `bool` | `true` | no |
| <a name="input_environment_id"></a> [environment\_id](#input\_environment\_id) | Immutable UUIDv7 generated before any external resource is created. | `string` | n/a | yes |
| <a name="input_environment_name"></a> [environment\_name](#input\_environment\_name) | Developer-selected lowercase environment slug. | `string` | n/a | yes |
| <a name="input_expires_at"></a> [expires\_at](#input\_expires\_at) | RFC3339 UTC lifecycle expiration. | `string` | n/a | yes |
| <a name="input_github_owner"></a> [github\_owner](#input\_github\_owner) | Owner of the generated repository. | `string` | `null` | no |
| <a name="input_github_repository"></a> [github\_repository](#input\_github\_repository) | Generated repository name. | `string` | `null` | no |
| <a name="input_image_repository"></a> [image\_repository](#input\_image\_repository) | Immutable generated-repository image namespace in apps/<numeric-repository-id> form. | `string` | n/a | yes |
| <a name="input_location"></a> [location](#input\_location) | Approved Azure deployment region. | `string` | `"westeurope"` | no |
| <a name="input_log_analytics_workspace_id"></a> [log\_analytics\_workspace\_id](#input\_log\_analytics\_workspace\_id) | Shared Log Analytics workspace resource ID. | `string` | n/a | yes |
| <a name="input_owner"></a> [owner](#input\_owner) | Requester login used for ownership and cleanup authorization. | `string` | n/a | yes |
| <a name="input_platform_admin_email"></a> [platform\_admin\_email](#input\_platform\_admin\_email) | Budget notification recipient. | `string` | n/a | yes |
| <a name="input_policy_definition_ids"></a> [policy\_definition\_ids](#input\_policy\_definition\_ids) | Platform policy definition IDs keyed by platform output names. | `map(string)` | `{}` | no |
| <a name="input_policy_effect"></a> [policy\_effect](#input\_policy\_effect) | Assignment effect for platform policies. | `string` | `"Audit"` | no |
| <a name="input_provisioning_channel"></a> [provisioning\_channel](#input\_provisioning\_channel) | github creates a per-repository OIDC identity; ade uses the project environment identity. | `string` | `"github"` | no |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Existing ADE-created resource group when create\_resource\_group is false. | `string` | `null` | no |
| <a name="input_shared_acr_id"></a> [shared\_acr\_id](#input\_shared\_acr\_id) | ARM ID of the shared platform ACR. The workload references but never owns it. | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional non-sensitive tags; reserved platform tags take precedence. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_deployment_client_id"></a> [deployment\_client\_id](#output\_deployment\_client\_id) | Generated-repository OIDC client ID; null for ADE. |
| <a name="output_deployment_principal_id"></a> [deployment\_principal\_id](#output\_deployment\_principal\_id) | Generated-repository OIDC principal ID; null for ADE. |
| <a name="output_endpoint"></a> [endpoint](#output\_endpoint) | Trusted public Container Apps HTTPS endpoint. |
| <a name="output_image_repository"></a> [image\_repository](#output\_image\_repository) | Exact ABAC-scoped repository that cleanup deletes after Terraform destroy. |
| <a name="output_resource_group_names"></a> [resource\_group\_names](#output\_resource\_group\_names) | All disposable resource groups tracked before cleanup. |
| <a name="output_resource_ids"></a> [resource\_ids](#output\_resource\_ids) | Disposable resource inventory; the shared ACR is intentionally excluded. |
| <a name="output_shared_acr_id"></a> [shared\_acr\_id](#output\_shared\_acr\_id) | Immutable shared registry ID paired with image\_repository for fail-closed cleanup. |
| <a name="output_state_contract"></a> [state\_contract](#output\_state\_contract) | Sanitizable lifecycle inventory contract persisted by the controller. |
<!-- END_TF_DOCS -->