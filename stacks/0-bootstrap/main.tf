# Stage 0 — bootstrap.
#
# Creates the three things every later stage assumes exist:
#
#   1. The playground folder, directly under the organization.
#   2. A seed project to hold Terraform state and shared tooling.
#   3. The state bucket itself.
#
# This is the only stack that names the organization, and it names it once, as the parent of a
# new folder. Creating a child does not alter anything the organization already applies to its
# other children — which is why scripts/guard.sh exempts google_folder specifically and blocks
# everything else that reaches for organizations/.
#
# Run once. After `make bootstrap-migrate` this stack's own state lives in the bucket it made.

locals {
  labels = {
    managed_by = "terraform"
    stack      = "0-bootstrap"
    purpose    = "study-playground"
  }
}

# --- The boundary -------------------------------------------------------------------------

resource "google_folder" "playground" {
  display_name = var.folder_name
  parent       = "organizations/${var.org_id}"

  # Everything this repo builds lives under this ID. If it ever changes, every other stack is
  # pointing at the wrong place, so it is worth being loud about.
  lifecycle {
    prevent_destroy = true
  }
}

# --- Seed project ----------------------------------------------------------------------------

resource "random_id" "seed" {
  byte_length = 2
}

resource "google_project" "seed" {
  name            = "${var.prefix}-seed-${random_id.seed.hex}"
  project_id      = "${var.prefix}-seed-${random_id.seed.hex}"
  folder_id       = google_folder.playground.folder_id
  billing_account = var.billing_account
  labels          = local.labels

  auto_create_network = false
  deletion_policy     = "PREVENT"
}

resource "google_project_service" "seed" {
  for_each = toset([
    "cloudresourcemanager.googleapis.com",
    "cloudbilling.googleapis.com",
    "iam.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
    "orgpolicy.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "cloudasset.googleapis.com",
    "pubsub.googleapis.com",
    "billingbudgets.googleapis.com",
    "essentialcontacts.googleapis.com",
    "compute.googleapis.com",
    "dns.googleapis.com",
    "cloudkms.googleapis.com",
    "iap.googleapis.com",
    "securitycenter.googleapis.com",
  ])

  project                    = google_project.seed.project_id
  service                    = each.value
  disable_on_destroy         = false
  disable_dependent_services = false
}

# --- State ---------------------------------------------------------------------------------------
#
# Versioning is not optional here. A corrupted or truncated state file with no prior version is
# an afternoon of `terraform import`, and this bucket is the single point of failure for every
# other stack.

resource "google_storage_bucket" "state" {
  name     = "${var.prefix}-tfstate-${random_id.seed.hex}"
  project  = google_project.seed.project_id
  location = var.default_region
  labels   = local.labels

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  # Keep 10 generations, expire the rest. Unbounded versioning on a state bucket quietly grows
  # forever; ten is more than enough to recover from anything recoverable.
  lifecycle_rule {
    condition {
      num_newer_versions = 10
      with_state         = "ARCHIVED"
    }
    action { type = "Delete" }
  }

  # `make nuke` must not be able to take the state with it.
  lifecycle {
    prevent_destroy = true
  }
}

# --- Folder-level budget -----------------------------------------------------------------------
#
# Covers everything under the playground folder, including projects that do not exist yet. This
# is the backstop for the per-project budgets the project module sets.

resource "google_billing_budget" "folder" {
  billing_account = replace(var.billing_account, "billingAccounts/", "")
  display_name    = "${var.prefix} study playground — folder total"

  budget_filter {
    # Empty projects list means the whole billing account; scoping by label keeps this to
    # resources this repo created rather than anything else on the account.
    labels = {
      purpose = "study-playground"
    }
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.budget_amount)
    }
  }

  dynamic "threshold_rules" {
    for_each = [0.5, 0.8, 1.0]
    content {
      threshold_percent = threshold_rules.value
      spend_basis       = "CURRENT_SPEND"
    }
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  depends_on = [google_project_service.seed]
}
