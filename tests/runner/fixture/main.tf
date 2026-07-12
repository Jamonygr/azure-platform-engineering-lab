terraform {
  required_version = "= 1.15.8"
}

variable "create_resource_group" { type = bool }
variable "resource_group_name" { type = string }
variable "environment_id" { type = string }
variable "environment_name" { type = string }
variable "owner" { type = string }
variable "expires_at" { type = string }
variable "location" { type = string }
variable "provisioning_channel" { type = string }
variable "github_owner" {
  type    = string
  default = null
}
variable "github_repository" {
  type    = string
  default = null
}

resource "terraform_data" "contract" {
  input = {
    create_resource_group = var.create_resource_group
    resource_group_name   = var.resource_group_name
    environment_id        = var.environment_id
    environment_name      = var.environment_name
    owner                 = var.owner
    expires_at            = var.expires_at
    location              = var.location
    provisioning_channel  = var.provisioning_channel
    github_owner          = var.github_owner
    github_repository     = var.github_repository
  }
}

output "endpoint" {
  value = "https://contract.example.invalid"
}

output "deployment_client_id" {
  value = "must-not-be-exported"
}
