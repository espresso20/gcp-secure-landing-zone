# Stage 1 — foundation.
#
# The controls that should outlive any individual experiment: org policy, audit collection,
# incident contacts. Cheap enough to leave running (well under $1/month at lab volume), which
# is why it is separated from stage 3, where the network lives and the meter runs.
#
# Everything attaches at folders/${var.folder_id}. Nothing here names the organization.

locals {
  parent = "folders/${var.folder_id}"

  labels = {
    managed_by = "terraform"
    stack      = "1-foundation"
    purpose    = "study-playground"
  }
}

# --- Organization policy ---------------------------------------------------------------------

module "org_policies" {
  source = "../../modules/org-policy-baseline"

  parent                   = local.parent
  customer_id              = var.customer_id
  enforce_cmek             = var.enforce_cmek
  boolean_policy_overrides = var.boolean_policy_overrides

  # Matches the budget posture: single-region US keeps egress and storage predictable.
  allowed_locations = ["in:us-locations"]
}

# --- Audit ---------------------------------------------------------------------------------------

module "audit_logging" {
  source = "../../modules/audit-logging"

  folder_id      = var.folder_id
  project_id     = var.seed_project
  region         = var.default_region
  prefix         = var.prefix
  retention_days = var.audit_retention_days
  labels         = local.labels

  # Left unlocked deliberately — see the module's variables.tf. A locked bucket strands
  # `make destroy` for a year.
  lock_retention = false
}

# --- Incident routing ------------------------------------------------------------------------------
#
# IR-6. Without this, Google's security notifications go to the org's default contacts, which
# for a personal org is one address that may not be watched.

resource "google_essential_contacts_contact" "security" {
  count = var.security_contact_email != null ? 1 : 0

  parent                              = local.parent
  email                               = var.security_contact_email
  language_tag                        = "en-US"
  notification_category_subscriptions = ["SECURITY", "TECHNICAL", "SUSPENSION"]
}

resource "google_essential_contacts_contact" "billing" {
  count = var.security_contact_email != null ? 1 : 0

  parent                              = local.parent
  email                               = var.security_contact_email
  language_tag                        = "en-US"
  notification_category_subscriptions = ["BILLING"]
}

# --- Organization-level read ------------------------------------------------------------------------
#
# Data sources only. These observe the organization to confirm the folder is where it is
# supposed to be; they cannot modify anything. This is the "org-level read" half of the
# blast-radius rule.

data "google_folder" "playground" {
  folder = local.parent
}

# Fails the plan if the folder ever ends up somewhere other than directly under an
# organization — for instance nested under another team's folder after a console drag.
check "folder_is_org_child" {
  assert {
    condition     = can(regex("^organizations/[0-9]+$", data.google_folder.playground.parent))
    error_message = "Playground folder's parent is ${data.google_folder.playground.parent}, expected an organization. Something moved it, and the blast-radius assumptions in docs/architecture.md no longer hold."
  }
}
