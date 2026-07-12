mock_provider "azapi" {}
mock_provider "azuread" {}

mock_provider "azurerm" {
  mock_data "azurerm_container_registry" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-platform-shared/providers/Microsoft.ContainerRegistry/registries/pelab000000acr"
      name         = "pelab000000acr"
      login_server = "pelab000000acr.azurecr.io"
    }
  }
}

run "web_app_contract" {
  command = plan

  module {
    source = "../../golden-paths/web-app-v1"
  }

  variables {
    environment_id             = "018f3f2a-7b6c-7def-8abc-0123456789ab"
    environment_name           = "test-web"
    owner                      = "octocat"
    expires_at                 = "2030-01-01T00:00:00Z"
    github_owner               = "example"
    github_repository          = "test-web"
    log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/shared/providers/Microsoft.OperationalInsights/workspaces/law"
    action_group_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/shared/providers/Microsoft.Insights/actionGroups/platform"
    platform_admin_email       = "platform@example.com"
  }

  assert {
    condition     = output.state_contract.golden_path == "web-app" && output.state_contract.path_version == "v1"
    error_message = "Web App must emit the stable v1 lifecycle contract."
  }

  assert {
    condition     = startswith(output.endpoint, "https://")
    error_message = "Web App endpoint must use HTTPS."
  }
}

run "aks_contract" {
  command = plan

  module {
    source = "../../golden-paths/aks-workload-v1"
  }

  variables {
    environment_id                  = "018f3f2a-7b6c-7def-8abc-0123456789ab"
    environment_name                = "test-aks"
    owner                           = "octocat"
    expires_at                      = "2030-01-01T00:00:00Z"
    github_owner                    = "example"
    github_repository               = "test-aks"
    developer_group_object_id       = "00000000-0000-0000-0000-000000000001"
    shared_acr_id                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-platform-shared/providers/Microsoft.ContainerRegistry/registries/pelab000000acr"
    image_repository                = "apps/123456789"
    default_domain_preflight_passed = true
    log_analytics_workspace_id      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/shared/providers/Microsoft.OperationalInsights/workspaces/law"
    action_group_id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/shared/providers/Microsoft.Insights/actionGroups/platform"
    platform_admin_email            = "platform@example.com"
  }

  override_module {
    target = module.aks
    outputs = {
      resource_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ContainerService/managedClusters/aks-test"
      name                           = "aks-test"
      node_resource_group_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test-nodes"
      node_resource_group_name       = "rg-test-nodes"
      oidc_issuer_profile_issuer_url = "https://oidc.prod-aks.azure.com/example/"
      kubelet_identity = {
        objectId   = "00000000-0000-0000-0000-000000000002"
        clientId   = "00000000-0000-0000-0000-000000000003"
        resourceId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/MC_test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/kubelet"
      }
    }
  }

  assert {
    condition     = output.endpoint_strategy == "aks-managed-default-domain"
    error_message = "AKS must require the managed HTTPS default-domain strategy."
  }

  assert {
    condition     = length(output.resource_group_names) == 2
    error_message = "AKS cleanup inventory must include its node resource group."
  }
}

run "reject_non_uuidv7" {
  command = plan

  module {
    source = "../../golden-paths/web-app-v1"
  }

  variables {
    environment_id             = "00000000-0000-4000-8000-000000000000"
    environment_name           = "bad-id"
    owner                      = "octocat"
    expires_at                 = "2030-01-01T00:00:00Z"
    github_owner               = "example"
    github_repository          = "bad-id"
    log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/shared/providers/Microsoft.OperationalInsights/workspaces/law"
    action_group_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/shared/providers/Microsoft.Insights/actionGroups/platform"
    platform_admin_email       = "platform@example.com"
  }

  expect_failures = [var.environment_id]
}
