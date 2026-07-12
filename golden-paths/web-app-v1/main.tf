locals {
  short_id            = substr(replace(lower(var.environment_id), "-", ""), 0, 8)
  generated_rg_name   = "rg-${var.environment_name}-web-${local.short_id}"
  resource_group_name = var.create_resource_group ? azurerm_resource_group.environment[0].name : data.azurerm_resource_group.environment[0].name
  resource_group_id   = var.create_resource_group ? azurerm_resource_group.environment[0].id : data.azurerm_resource_group.environment[0].id
  budget_start_date   = coalesce(var.budget_start_date, formatdate("YYYY-MM-01'T'00:00:00'Z'", plantimestamp()))
  tags = merge(var.tags, {
    "platform.environment_id" = lower(var.environment_id)
    "platform.environment"    = var.environment_name
    "platform.owner"          = var.owner
    "platform.expires_at"     = var.expires_at
    "platform.golden_path"    = "web-app-v1"
    "platform.channel"        = var.provisioning_channel
    "platform.public_https"   = "expected"
    "platform.managed"        = "terraform"
  })
}

resource "azurerm_resource_group" "environment" {
  count = var.create_resource_group ? 1 : 0

  name     = coalesce(var.resource_group_name, local.generated_rg_name)
  location = lower(var.location)
  tags     = local.tags
}

data "azurerm_resource_group" "environment" {
  count = var.create_resource_group ? 0 : 1

  name = var.resource_group_name
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

resource "azurerm_application_insights" "app" {
  name                = "appi-${var.environment_name}-${local.short_id}"
  location            = lower(var.location)
  resource_group_name = local.resource_group_name
  workspace_id        = var.log_analytics_workspace_id
  application_type    = "web"
  retention_in_days   = 30
  tags                = local.tags
}

module "service_plan" {
  source  = "Azure/avm-res-web-serverfarm/azurerm"
  version = "2.0.7"

  name                   = "asp-${var.environment_name}-${local.short_id}"
  location               = lower(var.location)
  parent_id              = local.resource_group_id
  os_type                = "Linux"
  sku_name               = "B1"
  worker_count           = 1
  zone_balancing_enabled = false
  enable_telemetry       = false
  tags                   = local.tags
}

module "web_app" {
  source  = "Azure/avm-res-web-site/azurerm"
  version = "0.22.0"

  name                          = "app-${var.environment_name}-${local.short_id}"
  location                      = lower(var.location)
  parent_id                     = local.resource_group_id
  service_plan_resource_id      = module.service_plan.resource_id
  kind                          = "webapp"
  os_type                       = "Linux"
  https_only                    = true
  public_network_access_enabled = true
  enable_telemetry              = false
  tags                          = local.tags

  managed_identities = {
    user_assigned_resource_ids = [azurerm_user_assigned_identity.runtime.id]
  }

  application_insights_connection_string = azurerm_application_insights.app.connection_string

  app_settings = {
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.app.connection_string
    ENVIRONMENT_ID                        = lower(var.environment_id)
    ENVIRONMENT_NAME                      = var.environment_name
    GOLDEN_PATH                           = "web-app"
    REGION_NAME                           = lower(var.location)
    SCM_DO_BUILD_DURING_DEPLOYMENT        = "true"
    WEBSITE_NODE_DEFAULT_VERSION          = "~24"
  }

  site_config = {
    always_on            = true
    ftps_state           = "Disabled"
    health_check_path    = "/healthz"
    http2_enabled        = true
    http_logging_enabled = true
    minimum_tls_version  = "1.3"
    application_stack = {
      node = {
        node_version = "24-lts"
      }
    }
  }

  diagnostic_settings = {
    platform = {
      name                  = "diag-web-${var.environment_name}-${local.short_id}"
      workspace_resource_id = var.log_analytics_workspace_id
      logs = [
        {
          category_group = "allLogs"
        }
      ]
      metrics = [
        {
          category = "AllMetrics"
        }
      ]
    }
  }
}

resource "azurerm_role_assignment" "deployment" {
  count = var.provisioning_channel == "github" ? 1 : 0

  scope                = module.web_app.resource_id
  role_definition_name = "Website Contributor"
  principal_id         = azurerm_user_assigned_identity.deployment[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_consumption_budget_resource_group" "environment" {
  name              = "budget-${var.environment_name}-${local.short_id}"
  resource_group_id = local.resource_group_id
  amount            = var.budget_amount
  time_grain        = "Monthly"

  time_period {
    start_date = local.budget_start_date
  }

  notification {
    enabled        = true
    threshold      = 50
    operator       = "GreaterThanOrEqualTo"
    threshold_type = "Actual"
    contact_emails = [var.platform_admin_email]
    contact_groups = [var.action_group_id]
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThanOrEqualTo"
    threshold_type = "Actual"
    contact_emails = [var.platform_admin_email]
    contact_groups = [var.action_group_id]
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThanOrEqualTo"
    threshold_type = "Actual"
    contact_emails = [var.platform_admin_email]
    contact_groups = [var.action_group_id]
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThanOrEqualTo"
    threshold_type = "Forecasted"
    contact_emails = [var.platform_admin_email]
    contact_groups = [var.action_group_id]
  }

  lifecycle {
    ignore_changes = [time_period[0].start_date]
  }
}

resource "azurerm_monitor_metric_alert" "http_5xx" {
  name                = "alert-${var.environment_name}-http5xx-${local.short_id}"
  resource_group_name = local.resource_group_name
  scopes              = [module.web_app.resource_id]
  description         = "Web App returned one or more HTTP 5xx responses."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT5M"
  tags                = local.tags

  criteria {
    metric_namespace = "Microsoft.Web/sites"
    metric_name      = "Http5xx"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0
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
  description          = "Platform guardrail assigned by web-app-v1."
  # Keep the assignment in Default enforcement mode for Audit as well as Deny.
  # The policy's effect parameter controls behavior; DoNotEnforce would weaken
  # the evidence produced by this lab.
  enforce = true
  parameters = jsonencode(merge(
    { effect = { value = var.policy_effect } },
    each.key == "allowed_eu_locations" ? { allowedLocations = { value = ["westeurope", "northeurope", "germanywestcentral"] } } : {}
  ))
}
