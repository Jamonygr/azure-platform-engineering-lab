package terraform.platform

import rego.v1

allowed_locations := {"westeurope", "northeurope", "germanywestcentral", "global"}

required_tags := {
	"platform.environment_id",
	"platform.owner",
	"platform.expires_at",
	"platform.golden_path",
	"platform.managed",
}

taggable_types := {
	"azurerm_resource_group",
	"azurerm_user_assigned_identity",
	"azurerm_application_insights",
	"azurerm_linux_web_app",
	"azurerm_service_plan",
	"azurerm_container_app_environment",
	"azurerm_container_app",
	"azurerm_kubernetes_cluster",
}

planned_resources contains resource if {
	some resource in input.resource_changes
	resource.mode == "managed"
	resource.change.actions != ["delete"]
}

deny contains sprintf("%s uses unapproved location %q", [resource.address, location]) if {
	some resource in planned_resources
	location := lower(object.get(resource.change.after, "location", "global"))
	location != ""
	not allowed_locations[location]
}

deny contains sprintf("%s is missing lifecycle tag %q", [resource.address, tag]) if {
	some resource in planned_resources
	taggable_types[resource.type]
	tags := object.get(resource.change.after, "tags", {})
	some tag in required_tags
	not tags[tag]
}

deny contains sprintf("%s enables a static Storage shared key", [resource.address]) if {
	some resource in planned_resources
	resource.type == "azurerm_storage_account"
	object.get(resource.change.after, "shared_access_key_enabled", true)
}

deny contains sprintf("%s exposes a non-private storage container", [resource.address]) if {
	some resource in planned_resources
	resource.type == "azurerm_storage_container"
	object.get(resource.change.after, "container_access_type", "private") != "private"
}

deny contains sprintf("%s has an untrusted workload identity issuer", [resource.address]) if {
	some resource in planned_resources
	resource.type == "azurerm_federated_identity_credential"
	object.get(resource.change.after, "issuer", "") != "https://token.actions.githubusercontent.com"
}

deny contains sprintf("%s has a non-deployment GitHub subject", [resource.address]) if {
	some resource in planned_resources
	resource.type == "azurerm_federated_identity_credential"
	subject := object.get(resource.change.after, "subject", "")
	not endswith(subject, ":environment:deployment")
	not endswith(subject, ":environment:platform")
	not endswith(subject, ":environment:lifecycle")
}

deny contains sprintf("%s allows plaintext App Service traffic", [resource.address]) if {
	some resource in planned_resources
	resource.type == "azurerm_linux_web_app"
	not object.get(resource.change.after, "https_only", false)
}

deny contains sprintf("%s allows insecure Container App ingress", [resource.address]) if {
	some resource in planned_resources
	resource.type == "azurerm_container_app"
	some ingress in object.get(resource.change.after, "ingress", [])
	object.get(ingress, "allow_insecure_connections", true)
}
