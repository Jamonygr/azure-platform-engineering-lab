locals {
  short_id            = substr(replace(lower(var.environment_id), "-", ""), 0, 8)
  generated_rg_name   = "rg-${var.environment_name}-ca-${local.short_id}"
  resource_group_name = var.create_resource_group ? azurerm_resource_group.environment[0].name : data.azurerm_resource_group.environment[0].name
  resource_group_id   = var.create_resource_group ? azurerm_resource_group.environment[0].id : data.azurerm_resource_group.environment[0].id
  acr_id_parts        = split("/", var.shared_acr_id)
  acr_resource_group  = local.acr_id_parts[4]
  acr_name            = local.acr_id_parts[8]
  budget_start_date   = coalesce(var.budget_start_date, formatdate("YYYY-MM-01'T'00:00:00'Z'", plantimestamp()))
  tags = merge(var.tags, {
    "platform.environment_id" = lower(var.environment_id)
    "platform.environment"    = var.environment_name
    "platform.owner"          = var.owner
    "platform.expires_at"     = var.expires_at
    "platform.golden_path"    = "container-app-v1"
    "platform.channel"        = var.provisioning_channel
    "platform.public_https"   = "expected"
    "platform.managed"        = "terraform"
  })

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

data "azurerm_container_registry" "shared" {
  name                = local.acr_name
  resource_group_name = local.acr_resource_group
}

resource "azurerm_user_assigned_identity" "runtime" {
  name                = "uami-${var.environment_name}-runtime-${local.short_id}"
  location            = lower(var.location)
  resource_group_name = local.resource_group_name
  tags                = local.tags
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

module "managed_environment" {
  source  = "Azure/avm-res-app-managedenvironment/azurerm"
  version = "0.5.0"

  name                  = "cae-${var.environment_name}-${local.short_id}"
  location              = lower(var.location)
  resource_group_name   = local.resource_group_name
  parent_id             = local.resource_group_id
  public_network_access = "Enabled"
  zone_redundant        = false
  enable_telemetry      = false
  tags                  = local.tags

  workload_profiles = [{
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }]

  log_analytics_workspace = {
    resource_id = var.log_analytics_workspace_id
  }
}

# The managed-environment API normalizes logAnalyticsDestinationType away.
# AVM 0.5.0 defaults that field to Dedicated, which creates perpetual drift.
# Keep the AVM for the environment and manage only this provider-normalized
# diagnostic setting at the root until the pinned module exposes a null value.
moved {
  from = module.managed_environment.azurerm_monitor_diagnostic_setting.this["platform"]
  to   = azurerm_monitor_diagnostic_setting.managed_environment
}

resource "azurerm_monitor_diagnostic_setting" "managed_environment" {
  name                       = "diag-cae-${var.environment_name}-${local.short_id}"
  target_resource_id         = module.managed_environment.resource_id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

module "container_app" {
  source  = "Azure/avm-res-app-containerapp/azurerm"
  version = "0.9.0"

  name                                  = "ca-${var.environment_name}-${local.short_id}"
  location                              = lower(var.location)
  resource_group_name                   = local.resource_group_name
  resource_group_id                     = local.resource_group_id
  container_app_environment_resource_id = module.managed_environment.resource_id
  revision_mode                         = "Single"
  max_inactive_revisions                = 1
  enable_telemetry                      = false
  tags                                  = local.tags

  managed_identities = {
    user_assigned_resource_ids = [azurerm_user_assigned_identity.runtime.id]
  }

  registries = [{
    server   = data.azurerm_container_registry.shared.login_server
    identity = azurerm_user_assigned_identity.runtime.id
  }]

  template = {
    min_replicas = 0
    max_replicas = 3
    containers = [{
      name   = "app"
      image  = var.container_image
      cpu    = 0.25
      memory = "0.5Gi"
      env = [
        { name = "ENVIRONMENT_ID", value = lower(var.environment_id) },
        { name = "ENVIRONMENT_NAME", value = var.environment_name },
        { name = "GOLDEN_PATH", value = "container-app" },
        { name = "REGION_NAME", value = lower(var.location) }
      ]
      # The immutable seed image listens on 80. With no explicit probes,
      # Container Apps supplies native TCP probes against the ingress target.
      # The generated workflow moves ingress to 3000 before deploying the
      # Node image, so its platform-managed probes follow the new target port.
    }]
  }

  ingress = {
    external_enabled           = true
    allow_insecure_connections = false
    target_port                = 80
    transport                  = "auto"
    traffic_weight = [{
      latest_revision = true
      percentage      = 100
    }]
  }
}

resource "azurerm_role_assignment" "runtime_acr_reader" {
  scope                = var.shared_acr_id
  role_definition_name = "Container Registry Repository Reader"
  principal_id         = azurerm_user_assigned_identity.runtime.principal_id
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition            = local.acr_reader_condition
}

resource "azurerm_role_assignment" "deployment_app" {
  count = var.provisioning_channel == "github" ? 1 : 0

  scope                = module.container_app.resource_id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.deployment[0].principal_id
  principal_type       = "ServicePrincipal"
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

resource "azurerm_monitor_activity_log_alert" "administrative_failure" {
  name                = "alert-${var.environment_name}-admin-${local.short_id}"
  resource_group_name = local.resource_group_name
  location            = "global"
  scopes              = [local.resource_group_id]
  description         = "Administrative failure in the disposable Container App resource group."
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
  description          = "Platform guardrail assigned by container-app-v1."
  # Audit and Deny both remain actively evaluated. The effect parameter, not
  # enforcementMode=DoNotEnforce, is the lab's policy control.
  enforce = true
  parameters = jsonencode(merge(
    { effect = { value = var.policy_effect } },
    each.key == "allowed_eu_locations" ? { allowedLocations = { value = ["westeurope", "northeurope", "germanywestcentral"] } } : {}
  ))
}
