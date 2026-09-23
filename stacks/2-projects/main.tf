# Stage 2 — projects.
#
# Three projects, separated by blast radius rather than by environment, because a one-person
# lab does not need dev/staging/prod but does need "the thing I can delete" kept away from "the
# thing that holds my VPC".
#
#   net       Shared VPC host. Long-lived; stage 3 configures the network inside it.
#   dev       Service project for workloads. Stage 4 builds here.
#   sandbox   Deliberately disposable. Break things here.
#
# Projects are free. Only what runs inside them costs anything, which is why three is not
# extravagant and why project-level separation is the cheapest security boundary GCP offers.

data "terraform_remote_state" "foundation" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "1-foundation"
  }
}

locals {
  # Confirms stage 1 ran and agrees with us about which folder this is, rather than trusting
  # config.env twice.
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

# --- Shared VPC host ----------------------------------------------------------------------------

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

# --- Workload projects ---------------------------------------------------------------------------

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

  # The point of a sandbox is that you can point it at things and see what breaks. Data access
  # logs stay on anyway: knowing what you did is the reason to have a sandbox.
  enable_data_access_logs = true
}
