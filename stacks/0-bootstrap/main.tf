# Stage 0: playground folder, seed project, state bucket.
#
# The only stack that names the organization, and only as the parent of a new folder. Creating
# a child does not change what the organization applies to its existing children, which is why
# scripts/guard.sh exempts google_folder and blocks everything else reaching for organizations/.
#
# Run once. `make bootstrap-migrate` then moves this stack's state into the bucket it created.

locals {
  labels = {
    managed_by = "terraform"
    stack      = "0-bootstrap"
    purpose    = "study-playground"
  }
}

resource "google_folder" "playground" {
  display_name = var.folder_name
  parent       = "organizations/${var.org_id}"

  # Every other stack is keyed to this ID.
  lifecycle {
    prevent_destroy = true
  }
}

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

# State bucket. Versioning is not optional: a truncated state file with no prior generation is
# an afternoon of `terraform import`.

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

  # Unbounded versioning on a state bucket grows forever. Ten generations is plenty.
  lifecycle_rule {
    condition {
      num_newer_versions = 10
      with_state         = "ARCHIVED"
    }
    action { type = "Delete" }
  }

  # `make nuke` must not take the state with it.
  lifecycle {
    prevent_destroy = true
  }
}

# Folder-level budget, covering projects that do not exist yet. Backstop for the per-project
# budgets in modules/project.

resource "google_billing_budget" "folder" {
  billing_account = replace(var.billing_account, "billingAccounts/", "")
  display_name    = "${var.prefix} study playground, folder total"

  budget_filter {
    # An empty projects list means the whole billing account, so scope by label instead.
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
