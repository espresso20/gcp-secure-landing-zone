# Project factory. Every project in this repo comes through here.
#
# Deleting a project does not free its project ID; the ID is burned permanently. Hence
# random_suffix, for a lab that gets rebuilt often.

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

  # The default VPC ships with allow-ssh and allow-rdp open to 0.0.0.0/0. CM-7, SC-7
  auto_create_network = false

  deletion_policy = "DELETE"
}

resource "google_project_service" "apis" {
  for_each = toset(var.activate_apis)

  project = google_project.this.project_id
  service = each.value

  # Disabling an API on destroy can cascade into dependent services and strand the destroy
  # halfway through.
  disable_on_destroy         = false
  disable_dependent_services = false
}

# DATA_READ and DATA_WRITE are off by default in GCP and are the ones that record who read the
# data. ADMIN_* are always on and cannot be disabled. Authoritative, so a console change to the
# audit config gets reverted on the next apply. AU-2, AU-12

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

resource "google_compute_shared_vpc_service_project" "attach" {
  count = var.shared_vpc_host_project != null ? 1 : 0

  host_project    = var.shared_vpc_host_project
  service_project = google_project.this.project_id

  depends_on = [google_project_service.apis]
}

# Not a NIST control. A forgotten GKE cluster is the likeliest way this repo costs real money.
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

  # Forecast fires before the money is spent; the current-spend rules above cannot.
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }
}
