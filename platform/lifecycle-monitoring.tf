locals {
  lifecycle_stream = "Custom-PlatformLifecycle"
  lifecycle_table  = "PlatformLifecycle_CL"
  lifecycle_columns = [
    { name = "TimeGenerated", type = "datetime" },
    { name = "Operation", type = "string" },
    { name = "EnvironmentId", type = "string" },
    { name = "Phase", type = "string" },
    { name = "Outcome", type = "string" },
    { name = "FencingGeneration", type = "int" },
    { name = "Message", type = "string" },
    { name = "RunUrl", type = "string" },
  ]
}

resource "azapi_resource" "lifecycle_log_table" {
  type      = "Microsoft.OperationalInsights/workspaces/tables@2023-09-01"
  name      = local.lifecycle_table
  parent_id = azurerm_log_analytics_workspace.platform[lower(var.location)].id
  body = {
    properties = {
      retentionInDays      = 90
      totalRetentionInDays = 90
      schema = {
        name    = local.lifecycle_table
        columns = local.lifecycle_columns
      }
    }
  }
}

resource "azapi_resource" "lifecycle_dcr" {
  type      = "Microsoft.Insights/dataCollectionRules@2024-03-11"
  name      = "dcr-platform-lifecycle-${var.unique_suffix}"
  parent_id = azurerm_resource_group.platform.id
  location  = azurerm_log_analytics_workspace.platform[lower(var.location)].location
  tags      = local.tags
  body = {
    kind = "Direct"
    properties = {
      description = "OIDC-authenticated platform lifecycle and heartbeat ingestion"
      streamDeclarations = {
        (local.lifecycle_stream) = {
          columns = local.lifecycle_columns
        }
      }
      destinations = {
        logAnalytics = [{
          name                = "platform-workspace"
          workspaceResourceId = azurerm_log_analytics_workspace.platform[lower(var.location)].id
        }]
      }
      dataFlows = [{
        streams      = [local.lifecycle_stream]
        destinations = ["platform-workspace"]
        transformKql = "source"
        outputStream = "Custom-${local.lifecycle_table}"
      }]
    }
  }

  response_export_values = {
    immutable_id            = "properties.immutableId"
    logs_ingestion_endpoint = "properties.endpoints.logsIngestion"
  }

  depends_on = [azapi_resource.lifecycle_log_table]
}

resource "azurerm_role_assignment" "lifecycle_logs_ingestion" {
  scope                = azapi_resource.lifecycle_dcr.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_user_assigned_identity.lifecycle.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "missing_reconciler_heartbeat" {
  name                    = "platform-reconciler-heartbeat-missing"
  resource_group_name     = azurerm_resource_group.platform.name
  location                = azurerm_resource_group.platform.location
  evaluation_frequency    = "PT15M"
  window_duration         = "PT30M"
  scopes                  = [azurerm_log_analytics_workspace.platform[lower(var.location)].id]
  severity                = 1
  enabled                 = true
  description             = "No successful platform lifecycle reconciler heartbeat was ingested for 30 minutes."
  display_name            = "Platform lifecycle reconciler heartbeat missing"
  auto_mitigation_enabled = true
  skip_query_validation   = true
  tags                    = local.tags

  criteria {
    query                   = "${local.lifecycle_table} | where Operation == 'heartbeat' and Outcome == 'success'"
    time_aggregation_method = "Count"
    threshold               = 1
    operator                = "LessThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.platform.id]
  }

  depends_on = [azapi_resource.lifecycle_log_table]
}
