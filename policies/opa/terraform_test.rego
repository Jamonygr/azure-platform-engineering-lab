package main

import rego.v1

base_tags := {
	"platform.environment_id": "018f3f2a-7b6c-7def-8abc-0123456789ab",
	"platform.environment": "test-web",
	"platform.owner": "octocat",
	"platform.expires_at": "2030-01-01T00:00:00Z",
	"platform.golden_path": "web-app-v1",
	"platform.channel": "github",
	"platform.managed": "terraform",
}

change(address, resource_type, after) := {
	"address": address,
	"type": resource_type,
	"change": {"actions": ["create"], "after": after},
}

no_op_change(address, resource_type, after) := {
	"address": address,
	"type": resource_type,
	"change": {"actions": ["no-op"], "after": after},
}

budget_change := change("azurerm_consumption_budget_resource_group.environment", "azurerm_consumption_budget_resource_group", {"amount": 10})

valid_web_plan := {"resource_changes": [
	change("azurerm_resource_group.environment", "azurerm_resource_group", {"location": "westeurope", "tags": base_tags}),
	change("module.web.azurerm_linux_web_app.this", "azurerm_linux_web_app", {
		"location": "westeurope",
		"tags": base_tags,
		"https_only": true,
		"site_config": [{"minimum_tls_version": "1.3"}],
	}),
	budget_change,
]}

valid_azapi_web_plan := {"resource_changes": [
	change("azurerm_resource_group.environment", "azurerm_resource_group", {"location": "westeurope", "tags": base_tags}),
	change("module.web_app.azapi_resource.this", "azapi_resource", {
		"type": "Microsoft.Web/sites@2025-03-01",
		"location": "westeurope",
		"tags": base_tags,
		"body": {"properties": {
			"httpsOnly": true,
			"siteConfig": {"minTlsVersion": "1.3"},
		}},
	}),
	budget_change,
]}

valid_azapi_container_plan := {"resource_changes": [
	change("module.container_app.azapi_resource.container_app", "azapi_resource", {
		"type": "Microsoft.App/containerApps@2025-02-02-preview",
		"location": "northeurope",
		"tags": base_tags,
		"body": {"properties": {
			"configuration": {"ingress": {"allowInsecure": false, "external": true}},
			"template": {"scale": {"minReplicas": 0, "maxReplicas": 3}},
		}},
	}),
	budget_change,
]}

valid_azapi_aks_plan := {"resource_changes": [
	change("module.aks.azapi_resource.this", "azapi_resource", {
		"type": "Microsoft.ContainerService/managedClusters@2026-03-01",
		"location": "germanywestcentral",
		"tags": base_tags,
		"body": {
			"sku": {"name": "Base", "tier": "Free"},
			"properties": {
				"disableLocalAccounts": true,
				"aadProfile": {"managed": true, "enableAzureRBAC": true},
				"agentPoolProfiles": [{
					"vmSize": "Standard_B2s",
					"enableAutoScaling": true,
					"minCount": 1,
					"maxCount": 2,
				}],
				"networkProfile": {
					"networkPlugin": "azure",
					"networkPluginMode": "overlay",
					"networkDataplane": "cilium",
				},
				"addonProfiles": {"azurepolicy": {"enabled": true}},
				"oidcIssuerProfile": {"enabled": true},
				"securityProfile": {"workloadIdentity": {"enabled": true}},
				"ingressProfile": {
					"gatewayAPI": {"installation": "Standard"},
					"webAppRouting": {"enabled": true},
				},
			},
		},
	}),
	budget_change,
]}

test_valid_web_plan_has_no_denials if {
	violations := deny with input as valid_web_plan
	count(violations) == 0
}

test_valid_avm_azapi_plans_have_no_denials if {
	web_violations := deny with input as valid_azapi_web_plan
	container_violations := deny with input as valid_azapi_container_plan
	aks_violations := deny with input as valid_azapi_aks_plan
	count(web_violations) == 0
	count(container_violations) == 0
	count(aks_violations) == 0
}

test_insecure_avm_web_app_is_denied if {
	bad := {"resource_changes": [
		change("module.web_app.azapi_resource.this", "azapi_resource", {
			"type": "Microsoft.Web/sites@2025-03-01",
			"tags": base_tags,
			"body": {"properties": {"httpsOnly": false, "siteConfig": {"minTlsVersion": "1.0"}}},
		}),
		budget_change,
	]}
	violations := deny with input as bad
	some message in violations
	contains(message, "HTTPS-only")
	some tls_message in violations
	contains(tls_message, "TLS 1.2")
}

test_insecure_or_overscaled_avm_container_app_is_denied if {
	bad := {"resource_changes": [
		change("module.container_app.azapi_resource.container_app", "azapi_resource", {
			"type": "Microsoft.App/containerApps@2025-02-02-preview",
			"tags": base_tags,
			"body": {"properties": {
				"configuration": {"ingress": {"allowInsecure": true, "external": false}},
				"template": {"scale": {"minReplicas": 2, "maxReplicas": 20}},
			}},
		}),
		budget_change,
	]}
	violations := deny with input as bad
	some insecure in violations
	contains(insecure, "insecure ingress")
	some replicas in violations
	contains(replicas, "three replicas")
}

test_insecure_or_oversized_avm_aks_is_denied if {
	bad := {"resource_changes": [
		change("module.aks.azapi_resource.this", "azapi_resource", {
			"type": "Microsoft.ContainerService/managedClusters@2026-03-01",
			"tags": base_tags,
			"body": {
				"sku": {"name": "Base", "tier": "Standard"},
				"properties": {
					"disableLocalAccounts": false,
					"aadProfile": {"managed": false, "enableAzureRBAC": false},
					"agentPoolProfiles": [{"vmSize": "Standard_D4s_v5", "enableAutoScaling": false, "minCount": 0, "maxCount": 5}],
					"networkProfile": {"networkPlugin": "kubenet", "networkPluginMode": "", "networkDataplane": "azure"},
					"addonProfiles": {"azurepolicy": {"enabled": false}},
					"oidcIssuerProfile": {"enabled": false},
					"securityProfile": {"workloadIdentity": {"enabled": false}},
					"ingressProfile": {"gatewayAPI": {"installation": "Disabled"}, "webAppRouting": {"enabled": false}},
				},
			},
		}),
		budget_change,
	]}
	violations := deny with input as bad
	some tier in violations
	contains(tier, "AKS Free tier")
	some accounts in violations
	contains(accounts, "disable local AKS accounts")
	some size in violations
	contains(size, "Standard_B2s")
	some identity in violations
	contains(identity, "workload identity")
}

test_avm_azapi_workload_requires_budget if {
	bad := {"resource_changes": [valid_azapi_web_plan.resource_changes[1]]}
	violations := deny with input as bad
	"A golden-path workload plan must include a resource-group budget" in violations
}

test_avm_azapi_workload_requires_tags if {
	bad := {"resource_changes": [
		change("module.web_app.azapi_resource.this", "azapi_resource", {
			"type": "Microsoft.Web/sites@2025-03-01",
			"tags": {},
			"body": {"properties": {"httpsOnly": true, "siteConfig": {"minTlsVersion": "1.3"}}},
		}),
		budget_change,
	]}
	violations := deny with input as bad
	some message in violations
	contains(message, "platform.environment_id")
}

test_disallowed_region_is_denied if {
	bad := object.union(valid_web_plan, {"resource_changes": [
		change("azurerm_resource_group.environment", "azurerm_resource_group", {"location": "eastus", "tags": base_tags}),
		budget_change,
	]})
	violations := deny with input as bad
	some message in violations
	contains(message, "disallowed Azure location")
}

test_global_control_plane_resource_is_allowed if {
	plan := {"resource_changes": [change("azurerm_monitor_activity_log_alert.environment", "azurerm_monitor_activity_log_alert", {"location": "Global"})]}
	violations := deny with input as plan
	count(violations) == 0
}

test_missing_tag_is_denied if {
	incomplete := object.remove(base_tags, {"platform.owner"})
	bad := {"resource_changes": [
		change("azurerm_resource_group.environment", "azurerm_resource_group", {"location": "westeurope", "tags": incomplete}),
		budget_change,
	]}
	violations := deny with input as bad
	some message in violations
	contains(message, "platform.owner")
}

test_insecure_web_app_is_denied if {
	bad := {"resource_changes": [
		change("azurerm_linux_web_app.bad", "azurerm_linux_web_app", {"tags": base_tags, "https_only": false, "site_config": [{"minimum_tls_version": "1.3"}]}),
		budget_change,
	]}
	violations := deny with input as bad
	some message in violations
	contains(message, "HTTPS-only")
}

test_insecure_container_app_is_denied if {
	bad := {"resource_changes": [
		change("azurerm_container_app.bad", "azurerm_container_app", {"tags": base_tags, "ingress": [{"allow_insecure_connections": true}]}),
		budget_change,
	]}
	violations := deny with input as bad
	some message in violations
	contains(message, "insecure ingress")
}

test_oversized_aks_is_denied if {
	bad := {"resource_changes": [
		change("azurerm_kubernetes_cluster.bad", "azurerm_kubernetes_cluster", {
			"tags": base_tags,
			"sku_tier": "Free",
			"default_node_pool": [{"vm_size": "Standard_D4s_v5", "max_count": 5}],
		}),
		budget_change,
	]}
	violations := deny with input as bad
	count(violations) >= 2
}

test_wrong_oidc_subject_is_denied if {
	bad := {"resource_changes": [change("azurerm_federated_identity_credential.bad", "azurerm_federated_identity_credential", {
		"issuer": "https://token.actions.githubusercontent.com",
		"subject": "repo:owner/repo:ref:refs/heads/main",
		"audience": ["api://AzureADTokenExchange"],
	})]}
	violations := deny with input as bad
	some message in violations
	contains(message, "deployment environment subject")
}

test_extra_oidc_audience_is_denied if {
	bad := {"resource_changes": [change("azurerm_federated_identity_credential.bad", "azurerm_federated_identity_credential", {
		"issuer": "https://token.actions.githubusercontent.com",
		"subject": "repo:owner/repo:environment:deployment",
		"audience": ["api://AzureADTokenExchange", "api://unexpected"],
	})]}
	violations := deny with input as bad
	some message in violations
	contains(message, "exactly one federated-credential audience")
}

test_workload_without_budget_is_denied if {
	bad := {"resource_changes": [change("azurerm_container_app.bad", "azurerm_container_app", {"tags": base_tags, "ingress": [{"allow_insecure_connections": false}]})]}
	violations := deny with input as bad
	"A golden-path workload plan must include a resource-group budget" in violations
}

test_expiry_update_accepts_retained_budget if {
	update := {
		"address": "azurerm_linux_web_app.updated",
		"type": "azurerm_linux_web_app",
		"change": {"actions": ["update"], "after": {
			"tags": object.union(base_tags, {"platform.expires_at": "2030-01-02T00:00:00Z"}),
			"https_only": true,
			"site_config": [{"minimum_tls_version": "1.3"}],
		}},
	}
	plan := {"resource_changes": [
		update,
		no_op_change("azurerm_consumption_budget_resource_group.environment", "azurerm_consumption_budget_resource_group", {"amount": 10}),
	]}
	violations := deny with input as plan
	count(violations) == 0
}

test_destroy_plan_is_not_blocked if {
	destroy := {"resource_changes": [{
		"address": "azurerm_resource_group.environment",
		"type": "azurerm_resource_group",
		"change": {"actions": ["delete"], "after": null},
	}]}
	violations := deny with input as destroy
	count(violations) == 0
}
