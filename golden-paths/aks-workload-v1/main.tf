locals {
  short_id            = substr(replace(lower(var.environment_id), "-", ""), 0, 8)
  generated_rg_name   = "rg-${var.environment_name}-aks-${local.short_id}"
  resource_group_name = var.create_resource_group ? azurerm_resource_group.environment[0].name : data.azurerm_resource_group.environment[0].name
  resource_group_id   = var.create_resource_group ? azurerm_resource_group.environment[0].id : data.azurerm_resource_group.environment[0].id
  node_resource_group = "rg-${var.environment_name}-aksnodes-${local.short_id}"
  workload_namespace  = var.provisioning_channel == "github" ? "golden-path" : "ade-node-sample"
  budget_start_date   = coalesce(var.budget_start_date, formatdate("YYYY-MM-01'T'00:00:00'Z'", plantimestamp()))
  tags = merge(var.tags, {
    "platform.environment_id" = lower(var.environment_id)
    "platform.environment"    = var.environment_name
    "platform.owner"          = var.owner
    "platform.expires_at"     = var.expires_at
    "platform.golden_path"    = "aks-workload-v1"
    "platform.channel"        = var.provisioning_channel
    "platform.public_https"   = "expected"
    "platform.managed"        = "terraform"
  })

  kubernetes_guardrails = {
    https_ingress = {
      definition_id = "/providers/Microsoft.Authorization/policyDefinitions/1a5b4dca-0b6f-4cf5-907c-56316bc1bf3d" # 9.0.*
      parameters    = {}
    }
    ingress_host = {
      definition_id = "/providers/Microsoft.Authorization/policyDefinitions/d8c942c6-16a3-400b-8f2e-785f44030036" # 1.1.* preview
      parameters    = {}
    }
    internal_load_balancer = {
      definition_id = "/providers/Microsoft.Authorization/policyDefinitions/3fc4dc25-5baf-40d8-9b05-7fe74c1bc64e" # 8.2.*
      parameters    = {}
    }
    no_external_ips = {
      definition_id = "/providers/Microsoft.Authorization/policyDefinitions/d46c275d-1680-448d-b2ec-e495a3b6cc89" # 5.2.*
      parameters    = { allowedExternalIPs = { value = [] } }
    }
    service_ports = {
      definition_id = "/providers/Microsoft.Authorization/policyDefinitions/233a2a17-77ca-4fb1-9b6b-69223d272a44" # 8.2.*
      parameters    = { allowedServicePortsList = { value = [80] } }
    }
  }

  acr_reader_condition = <<-CONDITION
    (
      !(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/content/read'})
      OR @Request[Microsoft.ContainerRegistry/registries/repositories:name] StringEqualsIgnoreCase '${var.image_repository}'
    )
    AND
    (
      !(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/metadata/read'})
      OR @Request[Microsoft.ContainerRegistry/registries/repositories:name] StringEqualsIgnoreCase '${var.image_repository}'
    )
  CONDITION

  acr_writer_condition = <<-CONDITION
    (
      !(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/content/read'})
      OR @Request[Microsoft.ContainerRegistry/registries/repositories:name] StringEqualsIgnoreCase '${var.image_repository}'
    )
    AND
    (
      !(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/content/write'})
      OR @Request[Microsoft.ContainerRegistry/registries/repositories:name] StringEqualsIgnoreCase '${var.image_repository}'
    )
    AND
    (
      !(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/metadata/read'})
      OR @Request[Microsoft.ContainerRegistry/registries/repositories:name] StringEqualsIgnoreCase '${var.image_repository}'
    )
    AND
    (
      !(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/metadata/write'})
      OR @Request[Microsoft.ContainerRegistry/registries/repositories:name] StringEqualsIgnoreCase '${var.image_repository}'
    )
  CONDITION
}

resource "azurerm_resource_group" "environment" {
  count = var.create_resource_group ? 1 : 0

  name     = coalesce(var.resource_group_name, local.generated_rg_name)
  location = lower(var.location)
  tags     = local.tags
}

data "azurerm_resource_group" "environment" {
  count = var.create_resource_group ? 0 : 1
  name  = var.resource_group_name
}

resource "azurerm_user_assigned_identity" "deployment" {
  count = var.provisioning_channel == "github" ? 1 : 0

  name                = "uami-${var.environment_name}-deploy-${local.short_id}"
  location            = lower(var.location)
  resource_group_name = local.resource_group_name
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "deployment" {
  count = var.provisioning_channel == "github" ? 1 : 0

  name                      = "github-deployment"
  user_assigned_identity_id = azurerm_user_assigned_identity.deployment[0].id
  issuer                    = "https://token.actions.githubusercontent.com"
  audience                  = ["api://AzureADTokenExchange"]
  subject                   = "repo:${var.github_owner}/${var.github_repository}:environment:deployment"
}

resource "terraform_data" "default_domain_preflight" {
  input = var.default_domain_preflight_passed

  lifecycle {
    precondition {
      condition     = var.default_domain_preflight_passed
      error_message = "AKS managed default-domain preflight did not pass. No insecure fallback is permitted."
    }
  }
}

module "aks" {
  source  = "Azure/avm-res-containerservice-managedcluster/azurerm"
  version = "0.6.7"

  name                   = "aks-${var.environment_name}-${local.short_id}"
  location               = lower(var.location)
  parent_id              = local.resource_group_id
  dns_prefix             = "aks-${var.environment_name}-${local.short_id}"
  node_resource_group    = local.node_resource_group
  kubernetes_version     = var.kubernetes_version
  sku                    = { name = "Base", tier = "Free" }
  enable_rbac            = true
  disable_local_accounts = true
  enable_telemetry       = false
  tags                   = local.tags

  managed_identities = {
    system_assigned = true
  }

  default_agent_pool = {
    name                = "system"
    count_of            = 1
    vm_size             = var.node_vm_size
    enable_auto_scaling = true
    min_count           = 1
    max_count           = 2
    max_pods            = 50
    os_disk_size_gb     = 64
    os_disk_type        = "Managed"
    os_sku              = "Ubuntu"
    type                = "VirtualMachineScaleSets"
    tags                = local.tags
    upgrade_settings = {
      max_surge = "10%"
    }
  }

  aad_profile = {
    managed                = true
    enable_azure_rbac      = true
    admin_group_object_ids = []
  }

  network_profile = {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_dataplane   = "cilium"
    network_policy      = "cilium"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
  }

  addon_profile_azure_policy = {
    enabled = true
  }

  addon_profile_oms_agent = {
    enabled = true
    config = {
      log_analytics_workspace_resource_id = var.log_analytics_workspace_id
      use_aad_auth                        = true
    }
  }

  oidc_issuer_profile = {
    enabled = true
  }

  security_profile = {
    image_cleaner = {
      enabled        = true
      interval_hours = 48
    }
    workload_identity = {
      enabled = true
    }
  }

  ingress_profile = {
    gateway_api = {
      installation = "Standard"
    }
    web_app_routing = {
      enabled = true
      gateway_api_implementations = {
        app_routing_istio = {
          mode = "Disabled"
        }
      }
    }
  }

  auto_upgrade_profile = {
    upgrade_channel         = "patch"
    node_os_upgrade_channel = "NodeImage"
  }

  diagnostic_settings = {
    platform = {
      name                  = "diag-aks-${var.environment_name}-${local.short_id}"
      workspace_resource_id = var.log_analytics_workspace_id
      log_groups            = ["allLogs"]
      metric_categories     = ["AllMetrics"]
    }
  }

  depends_on = [terraform_data.default_domain_preflight]
}

# AKS creates its managed node resource group outside this root's direct
# resource-group resource. Merge the immutable platform tags as soon as the
# cluster exists while preserving service-managed tags already on that group.
resource "azapi_update_resource" "node_resource_group_tags" {
  type        = "Microsoft.Resources/tags@2021-04-01"
  resource_id = "${module.aks.node_resource_group_id}/providers/Microsoft.Resources/tags/default"
  body = {
    operation = "Merge"
    properties = {
      tags = local.tags
    }
  }

  depends_on = [module.aks]
}

# Namespace creation is a cluster-scoped operation, so perform it once through
# the lifecycle/ADE control-plane identity before granting workload principals
# namespace-scoped Azure RBAC. Generated repositories never receive cluster
# administrator and cannot create a second, ungoverned namespace.
resource "azapi_resource_action" "workload_namespace" {
  type        = "Microsoft.ContainerService/managedClusters@2026-03-01"
  resource_id = module.aks.resource_id
  action      = "runCommand"
  method      = "POST"
  body = {
    command = "kubectl create namespace ${local.workload_namespace} --dry-run=client -o yaml | kubectl apply -f -"
    context = ""
  }
  response_export_values = ["properties.exitCode", "properties.provisioningState"]

  timeouts {
    create = "15m"
  }

  lifecycle {
    postcondition {
      condition = try(
        self.output.properties.exitCode == 0 && lower(self.output.properties.provisioningState) == "succeeded",
        false
      )
      error_message = "AKS workload namespace creation did not complete successfully; namespace-scoped access is not granted."
    }
  }

  depends_on = [module.aks]
}

resource "azurerm_role_assignment" "developer_cluster_user" {
  scope                = module.aks.resource_id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = var.developer_group_object_id
  principal_type       = "Group"
}

resource "azurerm_role_assignment" "developer_rbac_writer" {
  scope                = "${module.aks.resource_id}/namespaces/${local.workload_namespace}"
  role_definition_name = "Azure Kubernetes Service RBAC Writer"
  principal_id         = var.developer_group_object_id
  principal_type       = "Group"

  depends_on = [azapi_resource_action.workload_namespace]
}

# The developer group can write only in the selected workload namespace. These
# built-in Kubernetes.Data policies constrain that writable scope to the
# platform-managed HTTPS ingress pattern. System/app-routing namespaces are
# outside the developer's Azure RBAC scope and excluded from Gatekeeper policy.
resource "azurerm_resource_policy_assignment" "kubernetes_guardrail" {
  for_each = local.kubernetes_guardrails

  name                 = substr("pelab-k8s-${replace(each.key, "_", "-")}", 0, 64)
  resource_id          = module.aks.resource_id
  policy_definition_id = each.value.definition_id
  description          = "Deny non-golden-path Kubernetes exposure in namespace ${local.workload_namespace}."
  enforce              = true
  parameters = jsonencode(merge({
    source             = { value = "Original" }
    warn               = { value = false }
    effect             = { value = "Deny" }
    excludedNamespaces = { value = ["kube-system", "gatekeeper-system", "azure-arc", "azure-extensions-usage-system", "app-routing-system"] }
    namespaces         = { value = [local.workload_namespace] }
    labelSelector      = { value = {} }
  }, each.value.parameters))
}

resource "azurerm_role_assignment" "deployment_cluster_user" {
  count = var.provisioning_channel == "github" ? 1 : 0

  scope                = module.aks.resource_id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = azurerm_user_assigned_identity.deployment[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "deployment_rbac_writer" {
  count = var.provisioning_channel == "github" ? 1 : 0

  scope                = "${module.aks.resource_id}/namespaces/${local.workload_namespace}"
  role_definition_name = "Azure Kubernetes Service RBAC Writer"
  principal_id         = azurerm_user_assigned_identity.deployment[0].principal_id
  principal_type       = "ServicePrincipal"

  depends_on = [azapi_resource_action.workload_namespace]
}

resource "azurerm_role_assignment" "deployment_acr_writer" {
  count = var.provisioning_channel == "github" ? 1 : 0

  scope                = var.shared_acr_id
  role_definition_name = "Container Registry Repository Writer"
  principal_id         = azurerm_user_assigned_identity.deployment[0].principal_id
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition            = local.acr_writer_condition
}

resource "azurerm_role_assignment" "kubelet_acr_reader" {
  scope                = var.shared_acr_id
  role_definition_name = "Container Registry Repository Reader"
  principal_id         = module.aks.kubelet_identity.objectId
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition            = local.acr_reader_condition
}

resource "azurerm_consumption_budget_resource_group" "environment" {
  name              = "budget-${var.environment_name}-${local.short_id}"
  resource_group_id = local.resource_group_id
  amount            = var.budget_amount
  time_grain        = "Monthly"

  time_period {
    start_date = local.budget_start_date
  }

  dynamic "notification" {
    for_each = {
      actual_50    = { threshold = 50, type = "Actual" }
      actual_80    = { threshold = 80, type = "Actual" }
      actual_100   = { threshold = 100, type = "Actual" }
      forecast_100 = { threshold = 100, type = "Forecasted" }
    }
    content {
      enabled        = true
      threshold      = notification.value.threshold
      operator       = "GreaterThanOrEqualTo"
      threshold_type = notification.value.type
      contact_emails = [var.platform_admin_email]
      contact_groups = [var.action_group_id]
    }
  }

  lifecycle {
    ignore_changes = [time_period[0].start_date]
  }
}

# Most AKS compute cost accrues in the managed node resource group. A second
# budget ensures those charges are not invisible to the lab's alerting controls.
resource "azurerm_consumption_budget_resource_group" "nodes" {
  name              = "budget-${var.environment_name}-nodes-${local.short_id}"
  resource_group_id = module.aks.node_resource_group_id
  amount            = var.budget_amount
  time_grain        = "Monthly"

  time_period {
    start_date = local.budget_start_date
  }

  dynamic "notification" {
    for_each = {
      actual_50    = { threshold = 50, type = "Actual" }
      actual_80    = { threshold = 80, type = "Actual" }
      actual_100   = { threshold = 100, type = "Actual" }
      forecast_100 = { threshold = 100, type = "Forecasted" }
    }
    content {
      enabled        = true
      threshold      = notification.value.threshold
      operator       = "GreaterThanOrEqualTo"
      threshold_type = notification.value.type
      contact_emails = [var.platform_admin_email]
      contact_groups = [var.action_group_id]
    }
  }

  lifecycle {
    ignore_changes = [time_period[0].start_date]
  }
}

resource "azurerm_monitor_activity_log_alert" "administrative_failure" {
  name                = "alert-${var.environment_name}-admin-${local.short_id}"
  resource_group_name = local.resource_group_name
  location            = "global"
  scopes              = [local.resource_group_id]
  description         = "Administrative failure in the disposable AKS resource group."
  tags                = local.tags

  criteria {
    category = "Administrative"
    level    = "Error"
  }

  action {
    action_group_id = var.action_group_id
  }
}

resource "azurerm_resource_group_policy_assignment" "platform" {
  for_each = var.policy_definition_ids

  name                 = substr("pelab-${replace(each.key, "_", "-")}", 0, 64)
  resource_group_id    = local.resource_group_id
  policy_definition_id = each.value
  description          = "Platform guardrail assigned by aks-workload-v1."
  # Audit and Deny both remain actively evaluated. The effect parameter, not
  # enforcementMode=DoNotEnforce, is the lab's policy control.
  enforce = true
  parameters = jsonencode(merge(
    { effect = { value = var.policy_effect } },
    each.key == "allowed_eu_locations" ? { allowedLocations = { value = ["westeurope", "northeurope", "germanywestcentral"] } } : {}
  ))
}

# The AKS-managed node resource group contains the VMSS, load balancers, public
# IPs, disks, and networking resources. Apply the same environment guardrails
# there instead of treating it as an ungoverned implementation detail.
resource "azurerm_resource_group_policy_assignment" "node_platform" {
  for_each = var.policy_definition_ids

  name                 = substr("pelab-${replace(each.key, "_", "-")}", 0, 64)
  resource_group_id    = module.aks.node_resource_group_id
  policy_definition_id = each.value
  description          = "Platform guardrail assigned to the AKS managed node resource group by aks-workload-v1."
  enforce              = true
  parameters = jsonencode(merge(
    { effect = { value = var.policy_effect } },
    each.key == "allowed_eu_locations" ? { allowedLocations = { value = ["westeurope", "northeurope", "germanywestcentral"] } } : {}
  ))

  depends_on = [azapi_update_resource.node_resource_group_tags]
}
