# Stage 1: org policy, audit collection, incident contacts.
#
# Split from stage 3 because this tier is under $1/month and stays up, while the network tier
# is not. Everything attaches at folders/${var.folder_id}.

locals {
  parent = "folders/${var.folder_id}"

  labels = {
    managed_by = "terraform"
    stack      = "1-foundation"
    purpose    = "study-playground"
  }
}

module "org_policies" {
  source = "../../modules/org-policy-baseline"

  parent                   = local.parent
  customer_id              = var.customer_id
  enforce_cmek             = var.enforce_cmek
  boolean_policy_overrides = var.boolean_policy_overrides

  # Single-region US keeps egress and storage predictable.
  allowed_locations = ["in:us-locations"]
}

module "audit_logging" {
  source = "../../modules/audit-logging"

  folder_id      = var.folder_id
  project_id     = var.seed_project
  region         = var.default_region
  prefix         = var.prefix
  retention_days = var.audit_retention_days
  labels         = local.labels

  # Locking this strands `make destroy` for a year. See the module's variables.tf.
  lock_retention = false
}

# Without these, Google's security notifications go to the org default contacts, which on a
# personal org is one address nobody watches. IR-6

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

# Data sources only. These read the organization to confirm the folder is where it should be
# and cannot modify anything.

data "google_folder" "playground" {
  folder = local.parent
}

# Fails the plan if the folder is moved out from directly under the organization.
check "folder_is_org_child" {
  assert {
    condition     = can(regex("^organizations/[0-9]+$", data.google_folder.playground.parent))
    error_message = "Playground folder's parent is ${data.google_folder.playground.parent}, expected an organization. Something moved it, and the blast-radius assumptions in docs/architecture.md no longer hold."
  }
}
