# Stage 3 — network. DESTROYABLE TIER.
#
# This is where the meter starts. `make lab-down` tears down stage 3 and 4 together and leaves
# the foundation standing, which is the arrangement that keeps idle cost under $20/month.
#
# Bring it back with `make lab-up`. It takes a few minutes and costs nothing to recreate.

data "terraform_remote_state" "projects" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "2-projects"
  }
}

locals {
  net_project = data.terraform_remote_state.projects.outputs.net_project
  folder_id   = data.terraform_remote_state.projects.outputs.folder_id

  service_projects = {
    dev     = data.terraform_remote_state.projects.outputs.dev_project
    sandbox = data.terraform_remote_state.projects.outputs.sandbox_project
  }

  labels = {
    managed_by = "terraform"
    stack      = "3-network"
    purpose    = "study-playground"
  }
}

module "network" {
  source = "../../modules/secure-network"

  project_id = local.net_project
  folder_id  = local.folder_id
  prefix     = var.prefix
  region     = var.default_region
  enable_nat = var.enable_nat
  enable_dns = var.enable_dns
  labels     = local.labels
}

# --- Shared VPC attachment -------------------------------------------------------------------
#
# Lives here rather than in the project module because the host project must already be enabled
# as a host, and that happens inside the network module. Attaching from stage 2 would be a
# circular dependency across state files.

resource "google_compute_shared_vpc_service_project" "attached" {
  for_each = local.service_projects

  host_project    = local.net_project
  service_project = each.value

  depends_on = [module.network]
}

# --- Subnet-level IAM --------------------------------------------------------------------------
#
# AC-6 least privilege. Service project users get compute.networkUser on SPECIFIC subnets, not
# on the whole host project. Granting it at the project level is the common shortcut and it
# hands every service project access to every subnet, including ones it has no business in.

resource "google_compute_subnetwork_iam_member" "dev_app_subnet" {
  project    = local.net_project
  region     = var.default_region
  subnetwork = module.network.subnets["app"]

  role   = "roles/compute.networkUser"
  member = "serviceAccount:${data.terraform_remote_state.projects.outputs.project_numbers.dev}-compute@developer.gserviceaccount.com"

  depends_on = [google_compute_shared_vpc_service_project.attached]
}

# --- Encryption keys ------------------------------------------------------------------------------
#
# SC-12, SC-13, SC-28. Rotation is automatic; 90 days is the common moderate-baseline figure.
#
# Be aware: a KMS key ring can never be deleted, and neither can a key. `make lab-down` will
# leave these behind, and that is a GCP limitation rather than an oversight. Key versions cost
# about $0.06/month each, so the residue is pennies — but it is permanent, which is worth
# knowing before you run this in an org you care about.

resource "google_kms_key_ring" "lab" {
  project  = local.net_project
  name     = "${var.prefix}-lab"
  location = var.default_region

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key" "disk" {
  name            = "${var.prefix}-disk"
  key_ring        = google_kms_key_ring.lab.id
  rotation_period = "7776000s" # 90 days

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key" "storage" {
  name            = "${var.prefix}-storage"
  key_ring        = google_kms_key_ring.lab.id
  rotation_period = "7776000s"

  lifecycle {
    prevent_destroy = true
  }
}
