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
| <a name="module_service_plan"></a> [service\_plan](#module\_service\_plan) | Azure/avm-res-web-serverfarm/azurerm | 2.0.7 |
| <a name="module_web_app"></a> [web\_app](#module\_web\_app) | Azure/avm-res-web-site/azurerm | 0.22.0 |

## Resources

| Name | Type |
|------|------|
| [azurerm_application_insights.app](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/application_insights) | resource |
| [azurerm_consumption_budget_resource_group.environment](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/consumption_budget_resource_group) | resource |
| [azurerm_federated_identity_credential.deployment](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/federated_identity_credential) | resource |
| [azurerm_monitor_metric_alert.http_5xx](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/monitor_metric_alert) | resource |
| [azurerm_resource_group.environment](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/resource_group) | resource |
| [azurerm_resource_group_policy_assignment.platform](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/resource_group_policy_assignment) | resource |
| [azurerm_role_assignment.deployment](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_user_assigned_identity.deployment](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/user_assigned_identity) | resource |
| [azurerm_user_assigned_identity.runtime](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/user_assigned_identity) | resource |
| [azurerm_resource_group.environment](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/data-sources/resource_group) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_action_group_id"></a> [action\_group\_id](#input\_action\_group\_id) | Central action group resource ID. | `string` | n/a | yes |
| <a name="input_budget_amount"></a> [budget\_amount](#input\_budget\_amount) | Monthly cost-alert amount in the subscription billing currency. Budgets do not stop resources. | `number` | `10` | no |
| <a name="input_budget_start_date"></a> [budget\_start\_date](#input\_budget\_start\_date) | Optional first day of a month in RFC3339 form. Defaults to the plan month. | `string` | `null` | no |
| <a name="input_create_resource_group"></a> [create\_resource\_group](#input\_create\_resource\_group) | Create the environment resource group. ADE adapters set this false. | `bool` | `true` | no |
| <a name="input_environment_id"></a> [environment\_id](#input\_environment\_id) | Immutable UUIDv7 generated and inventoried before any external resource is created. | `string` | n/a | yes |
| <a name="input_environment_name"></a> [environment\_name](#input\_environment\_name) | Developer-selected lowercase environment slug. | `string` | n/a | yes |
| <a name="input_expires_at"></a> [expires\_at](#input\_expires\_at) | RFC3339 UTC expiration controlled by the lifecycle inventory. | `string` | n/a | yes |
| <a name="input_github_owner"></a> [github\_owner](#input\_github\_owner) | Owner of the generated repository; required for GitHub provisioning. | `string` | `null` | no |
| <a name="input_github_repository"></a> [github\_repository](#input\_github\_repository) | Generated repository name; required for GitHub provisioning. | `string` | `null` | no |
| <a name="input_location"></a> [location](#input\_location) | Approved Azure deployment region. | `string` | `"westeurope"` | no |
| <a name="input_log_analytics_workspace_id"></a> [log\_analytics\_workspace\_id](#input\_log\_analytics\_workspace\_id) | Shared Log Analytics workspace resource ID. | `string` | n/a | yes |
| <a name="input_owner"></a> [owner](#input\_owner) | Requester login used for ownership and cleanup authorization. | `string` | n/a | yes |
| <a name="input_platform_admin_email"></a> [platform\_admin\_email](#input\_platform\_admin\_email) | Budget notification recipient. | `string` | n/a | yes |
| <a name="input_policy_definition_ids"></a> [policy\_definition\_ids](#input\_policy\_definition\_ids) | Platform policy definition IDs keyed by the platform output names. | `map(string)` | `{}` | no |
| <a name="input_policy_effect"></a> [policy\_effect](#input\_policy\_effect) | Assignment effect for policies that expose an effect parameter. | `string` | `"Audit"` | no |
| <a name="input_provisioning_channel"></a> [provisioning\_channel](#input\_provisioning\_channel) | Provisioning adapter. GitHub creates an OIDC deployment identity; ADE uses its project identity. | `string` | `"github"` | no |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Existing ADE-created resource group name when create\_resource\_group is false. | `string` | `null` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional non-sensitive workload tags. Reserved platform tags take precedence. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_deployment_client_id"></a> [deployment\_client\_id](#output\_deployment\_client\_id) | Generated-repository OIDC client ID; null for ADE. |
| <a name="output_deployment_principal_id"></a> [deployment\_principal\_id](#output\_deployment\_principal\_id) | Generated-repository OIDC principal ID; null for ADE. |
| <a name="output_endpoint"></a> [endpoint](#output\_endpoint) | Trusted public HTTPS endpoint for the generated application repository. |
| <a name="output_resource_group_names"></a> [resource\_group\_names](#output\_resource\_group\_names) | All disposable resource groups tracked before cleanup. |
| <a name="output_resource_ids"></a> [resource\_ids](#output\_resource\_ids) | Disposable ARM resource inventory; shared resources are intentionally absent. |
| <a name="output_state_contract"></a> [state\_contract](#output\_state\_contract) | Sanitizable lifecycle inventory contract persisted by the controller. |
<!-- END_TF_DOCS -->