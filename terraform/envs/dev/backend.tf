terraform {
  # Partial configuration: bucket / region / kms_key_id come from backend.hcl
  #   terraform init -backend-config=backend.hcl
  backend "s3" {
    # bucket = <bucket-name> ==> This is deliberately left out and will be provided at terraform init. It's value is in the backend.hcl file, which is never committed to git
    key          = "envs/dev/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
