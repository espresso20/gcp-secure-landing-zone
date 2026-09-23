# Stage 3: network. Destroyable tier, and where the meter starts.
#
# `make lab-down` tears down stages 3 and 4 and leaves the foundation up. `make lab-up` brings
# it back in a few minutes.

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

# Attachment lives here, not in the project module: the host must be enabled as a host first,
# which happens in the network module. Doing it from stage 2 would be circular across states.

resource "google_compute_shared_vpc_service_project" "attached" {
  for_each = local.service_projects

  host_project    = local.net_project
  service_project = each.value

  depends_on = [module.network]
}

# compute.networkUser is granted per subnet, not on the host project. The project-level grant
# is the usual shortcut and it opens every subnet to every service project. AC-6

resource "google_compute_subnetwork_iam_member" "dev_app_subnet" {
  project    = local.net_project
  region     = var.default_region
  subnetwork = module.network.subnets["app"]

  role   = "roles/compute.networkUser"
  member = "serviceAccount:${data.terraform_remote_state.projects.outputs.project_numbers.dev}-compute@developer.gserviceaccount.com"

  depends_on = [google_compute_shared_vpc_service_project.attached]
}

# KMS key rings and keys cannot be deleted in GCP, so `make lab-down` leaves these behind.
# Key versions are about $0.06/month each. Rotation is automatic at 90 days. SC-12, SC-13, SC-28

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
