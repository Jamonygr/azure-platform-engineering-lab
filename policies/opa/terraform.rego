package main

import rego.v1

allowed_locations := {"westeurope", "northeurope", "germanywestcentral"}
allowed_tls_versions := {"1.2", "1.3"}

required_tags := {
	"platform.environment_id",
	"platform.environment",
	"platform.owner",
	"platform.expires_at",
	"platform.golden_path",
	"platform.channel",
	"platform.managed",
}

taggable_workload_types := {
	"azurerm_resource_group",
	"azurerm_service_plan",
	"azurerm_linux_web_app",
	"azurerm_application_insights",
	"azurerm_container_app_environment",
	"azurerm_container_app",
	"azurerm_kubernetes_cluster",
}

taggable_azapi_types := {
	"microsoft.web/serverfarms",
	"microsoft.web/sites",
	"microsoft.app/managedenvironments",
	"microsoft.app/containerapps",
	"microsoft.containerservice/managedclusters",
}

is_create_or_update(actions) if {
	some action in actions
	action in {"create", "update"}
}

planned_changes contains resource if {
	some resource in object.get(input, "resource_changes", [])
	is_create_or_update(resource.change.actions)
	resource.change.after != null
}

azapi_resource_type(resource) := lower(split(object.get(resource.change.after, "type", ""), "@")[0])

azapi_properties(resource) := object.get(object.get(resource.change.after, "body", {}), "properties", {})

is_azapi_type(resource, expected) if {
	resource.type == "azapi_resource"
	azapi_resource_type(resource) == lower(expected)
}

is_taggable_workload(resource) if {
	taggable_workload_types[resource.type]
}

is_taggable_workload(resource) if {
	resource_type := azapi_resource_type(resource)
	resource.type == "azapi_resource"
	taggable_azapi_types[resource_type]
}

is_web_workload(resource) if {
	resource.type == "azurerm_linux_web_app"
}

is_web_workload(resource) if {
	is_azapi_type(resource, "microsoft.web/sites")
}

is_container_workload(resource) if {
	resource.type == "azurerm_container_app"
}

is_container_workload(resource) if {
	is_azapi_type(resource, "microsoft.app/containerapps")
}

is_aks_workload(resource) if {
	resource.type == "azurerm_kubernetes_cluster"
}

is_aks_workload(resource) if {
	is_azapi_type(resource, "microsoft.containerservice/managedclusters")
}

is_workload(resource) if {
	is_web_workload(resource)
}

is_workload(resource) if {
	is_container_workload(resource)
}

is_workload(resource) if {
	is_aks_workload(resource)
}

deny contains message if {
	some resource in planned_changes
	location := lower(object.get(resource.change.after, "location", ""))
	location != ""
	location != "global"
	not allowed_locations[location]
	message := sprintf("%s uses disallowed Azure location %q", [resource.address, location])
}

deny contains message if {
	some resource in planned_changes
	is_taggable_workload(resource)
	tags := object.get(resource.change.after, "tags", {})
	some tag in required_tags
	object.get(tags, tag, "") == ""
	message := sprintf("%s is missing required tag %q", [resource.address, tag])
}

# Legacy AzureRM Web App shape retained for compatibility with reviewed v1
# state, plus the actual AVM 0.22.0 AzAPI shape used by new plans.
deny contains message if {
	some resource in planned_changes
	resource.type == "azurerm_linux_web_app"
	object.get(resource.change.after, "https_only", false) != true
	message := sprintf("%s must enforce HTTPS-only traffic", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	resource.type == "azurerm_linux_web_app"
	some site_config in object.get(resource.change.after, "site_config", [])
	tls := lower(object.get(site_config, "minimum_tls_version", ""))
	not allowed_tls_versions[tls]
	message := sprintf("%s must require TLS 1.2 or newer", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	is_azapi_type(resource, "microsoft.web/sites")
	properties := azapi_properties(resource)
	object.get(properties, "httpsOnly", false) != true
	message := sprintf("%s must enforce HTTPS-only traffic", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	is_azapi_type(resource, "microsoft.web/sites")
	properties := azapi_properties(resource)
	site_config := object.get(properties, "siteConfig", {})
	tls := lower(object.get(site_config, "minTlsVersion", ""))
	not allowed_tls_versions[tls]
	message := sprintf("%s must require TLS 1.2 or newer", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	resource.type == "azurerm_container_app"
	some ingress in object.get(resource.change.after, "ingress", [])
	object.get(ingress, "allow_insecure_connections", true) != false
	message := sprintf("%s must reject insecure ingress connections", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	is_azapi_type(resource, "microsoft.app/containerapps")
	properties := azapi_properties(resource)
	configuration := object.get(properties, "configuration", {})
	ingress := object.get(configuration, "ingress", {})
	object.get(ingress, "allowInsecure", true) != false
	message := sprintf("%s must reject insecure ingress connections", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	is_azapi_type(resource, "microsoft.app/containerapps")
	properties := azapi_properties(resource)
	configuration := object.get(properties, "configuration", {})
	ingress := object.get(configuration, "ingress", {})
	object.get(ingress, "external", false) != true
	message := sprintf("%s must expose only the expected public HTTPS ingress", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	is_azapi_type(resource, "microsoft.app/containerapps")
	properties := azapi_properties(resource)
	template := object.get(properties, "template", {})
	scale := object.get(template, "scale", {})
	object.get(scale, "minReplicas", 999) != 0
	message := sprintf("%s must keep the lab minimum at zero replicas", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	is_azapi_type(resource, "microsoft.app/containerapps")
	properties := azapi_properties(resource)
	template := object.get(properties, "template", {})
	scale := object.get(template, "scale", {})
	object.get(scale, "maxReplicas", 999) > 3
	message := sprintf("%s must cap the lab at three replicas", [resource.address])
}

# Legacy AzureRM AKS checks.
deny contains message if {
	some resource in planned_changes
	resource.type == "azurerm_kubernetes_cluster"
	lower(object.get(resource.change.after, "sku_tier", "")) != "free"
	message := sprintf("%s must use the bounded AKS Free tier", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	resource.type == "azurerm_kubernetes_cluster"
	some pool in object.get(resource.change.after, "default_node_pool", [])
	lower(object.get(pool, "vm_size", "")) != "standard_b2s"
	message := sprintf("%s must use Standard_B2s for the lab node pool", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	resource.type == "azurerm_kubernetes_cluster"
	some pool in object.get(resource.change.after, "default_node_pool", [])
	object.get(pool, "max_count", 999) > 2
	message := sprintf("%s node autoscaling maximum must not exceed two", [resource.address])
}

# AVM AKS 0.6.7 renders Microsoft.ContainerService/managedClusters through
# AzAPI. Inspect the body Azure receives, including the bounded lab profile.
deny contains message if {
	some resource in planned_changes
	is_azapi_type(resource, "microsoft.containerservice/managedclusters")
	body := object.get(resource.change.after, "body", {})
	sku := object.get(body, "sku", {})
	lower(object.get(sku, "tier", "")) != "free"
	message := sprintf("%s must use the bounded AKS Free tier", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	is_azapi_type(resource, "microsoft.containerservice/managedclusters")
	properties := azapi_properties(resource)
	object.get(properties, "disableLocalAccounts", false) != true
	message := sprintf("%s must disable local AKS accounts", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	is_azapi_type(resource, "microsoft.containerservice/managedclusters")
	properties := azapi_properties(resource)
	aad := object.get(properties, "aadProfile", {})
	object.get(aad, "managed", false) != true
	message := sprintf("%s must use managed Microsoft Entra integration", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	is_azapi_type(resource, "microsoft.containerservice/managedclusters")
	properties := azapi_properties(resource)
	aad := object.get(properties, "aadProfile", {})
	object.get(aad, "enableAzureRBAC", false) != true
	message := sprintf("%s must enable Azure RBAC for Kubernetes authorization", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	is_azapi_type(resource, "microsoft.containerservice/managedclusters")
	properties := azapi_properties(resource)
	pools := object.get(properties, "agentPoolProfiles", [])
	count(pools) == 0
	message := sprintf("%s must declare the bounded default agent pool", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	is_azapi_type(resource, "microsoft.containerservice/managedclusters")
	properties := azapi_properties(resource)
	some pool in object.get(properties, "agentPoolProfiles", [])
	lower(object.get(pool, "vmSize", "")) != "standard_b2s"
	message := sprintf("%s must use Standard_B2s for the lab node pool", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	is_azapi_type(resource, "microsoft.containerservice/managedclusters")
	properties := azapi_properties(resource)
	some pool in object.get(properties, "agentPoolProfiles", [])
	object.get(pool, "enableAutoScaling", false) != true
	message := sprintf("%s must enable bounded node autoscaling", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	is_azapi_type(resource, "microsoft.containerservice/managedclusters")
	properties := azapi_properties(resource)
	some pool in object.get(properties, "agentPoolProfiles", [])
	object.get(pool, "minCount", 999) != 1
	message := sprintf("%s node autoscaling minimum must be one", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	is_azapi_type(resource, "microsoft.containerservice/managedclusters")
	properties := azapi_properties(resource)
	some pool in object.get(properties, "agentPoolProfiles", [])
	object.get(pool, "maxCount", 999) > 2
	message := sprintf("%s node autoscaling maximum must not exceed two", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	is_azapi_type(resource, "microsoft.containerservice/managedclusters")
	properties := azapi_properties(resource)
	network := object.get(properties, "networkProfile", {})
	lower(object.get(network, "networkPlugin", "")) != "azure"
	message := sprintf("%s must use Azure CNI", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	is_azapi_type(resource, "microsoft.containerservice/managedclusters")
	properties := azapi_properties(resource)
	network := object.get(properties, "networkProfile", {})
	lower(object.get(network, "networkPluginMode", "")) != "overlay"
	message := sprintf("%s must use Azure CNI Overlay", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	is_azapi_type(resource, "microsoft.containerservice/managedclusters")
	properties := azapi_properties(resource)
	network := object.get(properties, "networkProfile", {})
	lower(object.get(network, "networkDataplane", "")) != "cilium"
	message := sprintf("%s must use the Cilium dataplane", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	is_azapi_type(resource, "microsoft.containerservice/managedclusters")
	properties := azapi_properties(resource)
	addons := object.get(properties, "addonProfiles", {})
	azure_policy := object.get(addons, "azurepolicy", {})
	object.get(azure_policy, "enabled", false) != true
	message := sprintf("%s must enable the Azure Policy add-on", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	is_azapi_type(resource, "microsoft.containerservice/managedclusters")
	properties := azapi_properties(resource)
	oidc := object.get(properties, "oidcIssuerProfile", {})
	object.get(oidc, "enabled", false) != true
	message := sprintf("%s must enable the AKS OIDC issuer", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	is_azapi_type(resource, "microsoft.containerservice/managedclusters")
	properties := azapi_properties(resource)
	security := object.get(properties, "securityProfile", {})
	workload_identity := object.get(security, "workloadIdentity", {})
	object.get(workload_identity, "enabled", false) != true
	message := sprintf("%s must enable AKS workload identity", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	is_azapi_type(resource, "microsoft.containerservice/managedclusters")
	properties := azapi_properties(resource)
	ingress := object.get(properties, "ingressProfile", {})
	gateway := object.get(ingress, "gatewayAPI", {})
	lower(object.get(gateway, "installation", "")) != "standard"
	message := sprintf("%s must use the approved managed Gateway API profile", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	is_azapi_type(resource, "microsoft.containerservice/managedclusters")
	properties := azapi_properties(resource)
	ingress := object.get(properties, "ingressProfile", {})
	routing := object.get(ingress, "webAppRouting", {})
	object.get(routing, "enabled", false) != true
	message := sprintf("%s must enable managed application routing", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	resource.type == "azurerm_federated_identity_credential"
	subject := object.get(resource.change.after, "subject", "")
	not regex.match(`^repo:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+:environment:deployment$`, subject)
	message := sprintf("%s must use the exact generated-repository deployment environment subject", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	resource.type == "azurerm_federated_identity_credential"
	object.get(resource.change.after, "issuer", "") != "https://token.actions.githubusercontent.com"
	message := sprintf("%s must trust only the GitHub Actions token issuer", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	resource.type == "azurerm_federated_identity_credential"
	audiences := object.get(resource.change.after, "audience", object.get(resource.change.after, "audiences", []))
	not "api://AzureADTokenExchange" in audiences
	message := sprintf("%s must use the Azure AD token-exchange audience", [resource.address])
}

deny contains message if {
	some resource in planned_changes
	resource.type == "azurerm_federated_identity_credential"
	audiences := object.get(resource.change.after, "audience", object.get(resource.change.after, "audiences", []))
	count(audiences) != 1
	message := sprintf("%s must declare exactly one federated-credential audience", [resource.address])
}

creating_workload if {
	some resource in planned_changes
	is_workload(resource)
}

has_budget if {
	some resource in object.get(input, "resource_changes", [])
	resource.type == "azurerm_consumption_budget_resource_group"
	resource.change.after != null
}

deny contains "A golden-path workload plan must include a resource-group budget" if {
	creating_workload
	not has_budget
}
