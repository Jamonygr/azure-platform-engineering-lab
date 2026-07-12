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
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_aks"></a> [aks](#module\_aks) | Azure/avm-res-containerservice-managedcluster/azurerm | 0.6.7 |

## Resources

| Name | Type |
|------|------|
| [azapi_resource_action.workload_namespace](https://registry.terraform.io/providers/Azure/azapi/2.10.0/docs/resources/resource_action) | resource |
| [azapi_update_resource.node_resource_group_tags](https://registry.terraform.io/providers/Azure/azapi/2.10.0/docs/resources/update_resource) | resource |
| [azurerm_consumption_budget_resource_group.environment](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/consumption_budget_resource_group) | resource |
| [azurerm_consumption_budget_resource_group.nodes](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/consumption_budget_resource_group) | resource |
| [azurerm_federated_identity_credential.deployment](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/federated_identity_credential) | resource |
| [azurerm_monitor_activity_log_alert.administrative_failure](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/monitor_activity_log_alert) | resource |
| [azurerm_resource_group.environment](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/resource_group) | resource |
| [azurerm_resource_group_policy_assignment.node_platform](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/resource_group_policy_assignment) | resource |
| [azurerm_resource_group_policy_assignment.platform](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/resource_group_policy_assignment) | resource |
| [azurerm_resource_policy_assignment.kubernetes_guardrail](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/resource_policy_assignment) | resource |
| [azurerm_role_assignment.deployment_acr_writer](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.deployment_cluster_user](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.deployment_rbac_writer](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.developer_cluster_user](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.developer_rbac_writer](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.kubelet_acr_reader](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/role_assignment) | resource |
| [azurerm_user_assigned_identity.deployment](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/user_assigned_identity) | resource |
| [terraform_data.default_domain_preflight](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [azurerm_resource_group.environment](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/data-sources/resource_group) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_action_group_id"></a> [action\_group\_id](#input\_action\_group\_id) | Central action group resource ID. | `string` | n/a | yes |
| <a name="input_budget_amount"></a> [budget\_amount](#input\_budget\_amount) | Monthly alert amount in subscription currency; it does not stop consumption. | `number` | `75` | no |
| <a name="input_budget_start_date"></a> [budget\_start\_date](#input\_budget\_start\_date) | Optional first day of a month in RFC3339 form. | `string` | `null` | no |
| <a name="input_create_resource_group"></a> [create\_resource\_group](#input\_create\_resource\_group) | Create the environment resource group. ADE adapters set this false. | `bool` | `true` | no |
| <a name="input_default_domain_preflight_passed"></a> [default\_domain\_preflight\_passed](#input\_default\_domain\_preflight\_passed) | Set only after `az aks approuting defaultdomain` availability is verified in the chosen subscription/region. | `bool` | `false` | no |
| <a name="input_developer_group_object_id"></a> [developer\_group\_object\_id](#input\_developer\_group\_object\_id) | Existing Entra developer group granted Azure RBAC access to this dedicated cluster. | `string` | n/a | yes |
| <a name="input_environment_id"></a> [environment\_id](#input\_environment\_id) | Immutable UUIDv7 generated before any external resource is created. | `string` | n/a | yes |
| <a name="input_environment_name"></a> [environment\_name](#input\_environment\_name) | Developer-selected lowercase environment slug. | `string` | n/a | yes |
| <a name="input_expires_at"></a> [expires\_at](#input\_expires\_at) | RFC3339 UTC lifecycle expiration. | `string` | n/a | yes |
| <a name="input_github_owner"></a> [github\_owner](#input\_github\_owner) | Owner of the generated repository. | `string` | `null` | no |
| <a name="input_github_repository"></a> [github\_repository](#input\_github\_repository) | Generated repository name. | `string` | `null` | no |
| <a name="input_image_repository"></a> [image\_repository](#input\_image\_repository) | Immutable generated-repository image namespace in apps/<numeric-repository-id> form. | `string` | n/a | yes |
| <a name="input_kubernetes_version"></a> [kubernetes\_version](#input\_kubernetes\_version) | Optional supported AKS major.minor version. Null selects the current regional default. | `string` | `null` | no |
| <a name="input_location"></a> [location](#input\_location) | Approved Azure deployment region. | `string` | `"westeurope"` | no |
| <a name="input_log_analytics_workspace_id"></a> [log\_analytics\_workspace\_id](#input\_log\_analytics\_workspace\_id) | Shared Log Analytics workspace resource ID used by Container Insights. | `string` | n/a | yes |
| <a name="input_node_vm_size"></a> [node\_vm\_size](#input\_node\_vm\_size) | Low-cost system node VM size, subject to regional quota preflight. | `string` | `"Standard_B2s"` | no |
| <a name="input_owner"></a> [owner](#input\_owner) | Requester login used for ownership and cleanup authorization. | `string` | n/a | yes |
| <a name="input_platform_admin_email"></a> [platform\_admin\_email](#input\_platform\_admin\_email) | Budget notification recipient. | `string` | n/a | yes |
| <a name="input_policy_definition_ids"></a> [policy\_definition\_ids](#input\_policy\_definition\_ids) | Platform policy definition IDs keyed by platform output names. | `map(string)` | `{}` | no |
| <a name="input_policy_effect"></a> [policy\_effect](#input\_policy\_effect) | Assignment effect for platform policies. | `string` | `"Audit"` | no |
| <a name="input_provisioning_channel"></a> [provisioning\_channel](#input\_provisioning\_channel) | github creates a per-repository OIDC identity; ade uses the project environment identity. | `string` | `"github"` | no |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Existing ADE-created resource group when create\_resource\_group is false. | `string` | `null` | no |
| <a name="input_shared_acr_id"></a> [shared\_acr\_id](#input\_shared\_acr\_id) | ARM ID of the shared ABAC-mode platform ACR. | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional non-sensitive tags; reserved platform tags take precedence. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | AKS cluster name used by the approved deployment workflow. |
| <a name="output_deployment_client_id"></a> [deployment\_client\_id](#output\_deployment\_client\_id) | Generated-repository OIDC client ID; null for ADE. |
| <a name="output_deployment_principal_id"></a> [deployment\_principal\_id](#output\_deployment\_principal\_id) | Generated-repository OIDC principal ID; null for ADE. |
| <a name="output_endpoint"></a> [endpoint](#output\_endpoint) | Application endpoint is discovered after Helm deploy and default-domain enablement. |
| <a name="output_endpoint_strategy"></a> [endpoint\_strategy](#output\_endpoint\_strategy) | Controller instruction for resolving the post-deployment HTTPS endpoint. |
| <a name="output_image_repository"></a> [image\_repository](#output\_image\_repository) | Exact ABAC-scoped repository that cleanup deletes after Terraform destroy. |
| <a name="output_node_resource_group"></a> [node\_resource\_group](#output\_node\_resource\_group) | Explicit node resource group tracked as a first-class disposable resource. |
| <a name="output_oidc_issuer_url"></a> [oidc\_issuer\_url](#output\_oidc\_issuer\_url) | AKS workload identity issuer for application service accounts. |
| <a name="output_resource_group_names"></a> [resource\_group\_names](#output\_resource\_group\_names) | Primary and AKS-managed node resource groups that cleanup must verify absent. |
| <a name="output_resource_ids"></a> [resource\_ids](#output\_resource\_ids) | Disposable resource inventory; the shared ACR is intentionally excluded. |
| <a name="output_shared_acr_id"></a> [shared\_acr\_id](#output\_shared\_acr\_id) | Immutable shared registry ID paired with image\_repository for fail-closed cleanup. |
| <a name="output_state_contract"></a> [state\_contract](#output\_state\_contract) | Sanitizable lifecycle inventory contract persisted by the controller. |
<!-- END_TF_DOCS -->