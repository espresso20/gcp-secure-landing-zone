# Stage 2: three projects, split by blast radius rather than by environment.
#
#   net       Shared VPC host. Stage 3 configures the network inside it.
#   dev       Service project for workloads. Stage 4 builds here.
#   sandbox   Disposable.
#
# Projects themselves are free; only what runs in them bills.

data "terraform_remote_state" "foundation" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "1-foundation"
  }
}

locals {
  # Take the folder from stage 1's state rather than trusting config.env twice.
  folder_id = data.terraform_remote_state.foundation.outputs.folder_id

  base_labels = {
    managed_by = "terraform"
    stack      = "2-projects"
    purpose    = "study-playground"
  }

  common_apis = [
    "compute.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ]
}

check "folder_matches_config" {
  assert {
    condition     = local.folder_id == var.folder_id
    error_message = "config.env says folder ${var.folder_id} but stage 1 state says ${local.folder_id}. One of them is stale; do not apply until they agree."
  }
}

module "net" {
  source = "../../modules/project"

  name            = "net"
  prefix          = var.prefix
  folder_id       = local.folder_id
  billing_account = var.billing_account
  budget_amount   = var.budget_amount
  labels          = merge(local.base_labels, { role = "shared-vpc-host" })

  activate_apis = concat(local.common_apis, [
    "dns.googleapis.com",
    "networkmanagement.googleapis.com",
    "servicenetworking.googleapis.com",
  ])
}

module "dev" {
  source = "../../modules/project"

  name            = "dev"
  prefix          = var.prefix
  folder_id       = local.folder_id
  billing_account = var.billing_account
  budget_amount   = var.budget_amount
  labels          = merge(local.base_labels, { role = "workload", tier = "dev" })

  activate_apis = concat(local.common_apis, [
    "cloudkms.googleapis.com",
    "iap.googleapis.com",
    "storage.googleapis.com",
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "oslogin.googleapis.com",
  ])
}

module "sandbox" {
  source = "../../modules/project"

  name            = "sandbox"
  prefix          = var.prefix
  folder_id       = local.folder_id
  billing_account = var.billing_account
  budget_amount   = var.budget_amount
  labels          = merge(local.base_labels, { role = "workload", tier = "sandbox" })

  activate_apis = concat(local.common_apis, [
    "storage.googleapis.com",
    "iap.googleapis.com",
    "oslogin.googleapis.com",
  ])

  # Left on even here. Knowing what you broke is the point of a sandbox.
  enable_data_access_logs = true
}
