package terraform.platform_test

import rego.v1

import data.terraform.platform

secure_plan := {"resource_changes": [
	{
		"address": "azurerm_resource_group.environment",
		"mode": "managed",
		"type": "azurerm_resource_group",
		"change": {
			"actions": ["create"],
			"after": {
				"location": "westeurope",
				"tags": {
					"platform.environment_id": "018f3f2a-7b6c-7def-8abc-0123456789ab",
					"platform.owner": "octocat",
					"platform.expires_at": "2030-01-01T00:00:00Z",
					"platform.golden_path": "web-app-v1",
					"platform.managed": "terraform",
				},
			},
		},
	},
	{
		"address": "azurerm_federated_identity_credential.deployment",
		"mode": "managed",
		"type": "azurerm_federated_identity_credential",
		"change": {
			"actions": ["create"],
			"after": {
				"issuer": "https://token.actions.githubusercontent.com",
				"subject": "repo:example/app:environment:deployment",
			},
		},
	},
]}

test_secure_plan_has_no_denials if {
	denials := platform.deny with input as secure_plan
	count(denials) == 0
}

test_static_storage_key_is_denied if {
	plan := {"resource_changes": [{
		"address": "azurerm_storage_account.bad",
		"mode": "managed",
		"type": "azurerm_storage_account",
		"change": {
			"actions": ["create"],
			"after": {
				"location": "westeurope",
				"shared_access_key_enabled": true,
			},
		},
	}]}
	denials := platform.deny with input as plan
	some message in denials
	contains(message, "static Storage shared key")
}

test_wrong_oidc_subject_is_denied if {
	plan := {"resource_changes": [{
		"address": "azurerm_federated_identity_credential.bad",
		"mode": "managed",
		"type": "azurerm_federated_identity_credential",
		"change": {
			"actions": ["create"],
			"after": {
				"issuer": "https://token.actions.githubusercontent.com",
				"subject": "repo:example/app:ref:refs/heads/main",
			},
		},
	}]}
	denials := platform.deny with input as plan
	some message in denials
	contains(message, "non-deployment GitHub subject")
}
