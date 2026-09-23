# Project factory.
#
# Every project in this repo comes through here, so the things that are easy to forget — audit
# config, no default network, a lien, labels, budget — are structural rather than remembered.
#
# Worth knowing for the exam: deleting a project does NOT free its project ID. The ID is burned
# permanently. A lab you tear down and rebuild weekly will exhaust any fixed naming scheme,
# which is what random_suffix is for.

resource "random_id" "suffix" {
  count       = var.random_suffix ? 1 : 0
  byte_length = 2
}

locals {
  suffix     = var.random_suffix ? "-${random_id.suffix[0].hex}" : ""
  project_id = "${var.prefix}-${var.name}${local.suffix}"
}

resource "google_project" "this" {
  name            = local.project_id
  project_id      = local.project_id
  folder_id       = var.folder_id
  billing_account = var.billing_account
  labels          = var.labels

  # CM-7, SC-7 — the default VPC ships with permissive rules (allow-internal, allow-ssh from
  # 0.0.0.0/0, allow-rdp from 0.0.0.0/0). The org policy also blocks this; belt and braces,
  # because the policy is only as good as its attachment point.
  auto_create_network = false

  # Terraform deletes projects happily, and in a lab that is the desired behaviour.
  deletion_policy = "DELETE"
}

resource "google_project_service" "apis" {
  for_each = toset(var.activate_apis)

  project = google_project.this.project_id
  service = each.value

  # Leave APIs enabled on destroy. Disabling an API can cascade into dependent services in ways
  # that make a destroy fail halfway and leave the project in a state neither Terraform nor a
  # human can easily reason about.
  disable_on_destroy         = false
  disable_dependent_services = false
}

# --- AU-2 / AU-12: audit configuration -------------------------------------------------------
#
# ADMIN_READ/ADMIN_WRITE are always on in GCP and cannot be disabled. DATA_READ and DATA_WRITE
# are off by default, and they are the ones that tell you who read the data.
#
# This is authoritative: it replaces the project's whole audit config. That is the point — a
# non-authoritative version would let a manual console change silently stay.

resource "google_project_iam_audit_config" "all_services" {
  count = var.enable_data_access_logs ? 1 : 0

  project = google_project.this.project_id
  service = "allServices"

  audit_log_config {
    log_type         = "ADMIN_READ"
    exempted_members = var.data_access_log_exemptions
  }

  audit_log_config {
    log_type         = "DATA_READ"
    exempted_members = var.data_access_log_exemptions
  }

  audit_log_config {
    log_type         = "DATA_WRITE"
    exempted_members = var.data_access_log_exemptions
  }

  depends_on = [google_project_service.apis]
}

# --- Shared VPC attachment --------------------------------------------------------------------

resource "google_compute_shared_vpc_service_project" "attach" {
  count = var.shared_vpc_host_project != null ? 1 : 0

  host_project    = var.shared_vpc_host_project
  service_project = google_project.this.project_id

  depends_on = [google_project_service.apis]
}

# --- Cost guard ---------------------------------------------------------------------------------
#
# Not a NIST control. It is here because an unattended lab with a forgotten GKE cluster is the
# most likely way this repo actually hurts someone.

resource "google_billing_budget" "this" {
  count = var.budget_amount > 0 ? 1 : 0

  billing_account = replace(var.billing_account, "billingAccounts/", "")
  display_name    = "${local.project_id} monthly"

  budget_filter {
    projects = ["projects/${google_project.this.number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.budget_amount)
    }
  }

  dynamic "threshold_rules" {
    for_each = [0.5, 0.9, 1.0]
    content {
      threshold_percent = threshold_rules.value
      spend_basis       = "CURRENT_SPEND"
    }
  }

  # Forecasted spend catches the runaway before the money is gone, which the current-spend
  # thresholds above structurally cannot.
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }
}
