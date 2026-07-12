# Terraform tests

- `golden_paths.tftest.hcl` uses mocked providers to test the public inputs and
  lifecycle outputs without creating Azure resources. It exercises Web App and
  AKS plus negative UUID validation. Container Apps is covered by init/validate
  and the offline contract checks because its pinned AVM module uses an
  ephemeral AzAPI action, which Terraform mock providers do not yet support.
  Run it with Terraform 1.15.8 after `terraform init` has populated the pinned
  AVM modules.
- `policy/` contains Conftest/OPA rules and unit tests for regions, lifecycle
  tags, HTTPS, OIDC subjects, private containers, and disabled Shared Key.
- `verify-contracts.ps1` is fully offline and verifies the stable controller
  contract plus policy JSON syntax.

Example:

```powershell
./tests/terraform/verify-contracts.ps1
opa test ./tests/terraform/policy
terraform -chdir=./tests/terraform init
terraform -chdir=./tests/terraform test
```
