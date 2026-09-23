# Organization-level baseline. LAB ORGANIZATION ONLY.
#
# Everything here writes at the organization node, which the rest of this repo exists to
# prevent. It is here because three things have no folder-scoped form:
#
#   * Custom org policy constraints, defined only at the organization.
#   * Org-wide log sinks, which see folders created later; a folder sink does not.
#   * Organization IAM, including the default grants new domain users receive.
#
# Applied to an organization that already holds workloads, these constraints reach them
# immediately by inheritance.
#
# Three things must agree first: ORG_WRITES_ALLOWED_FOR in config.env, the guard's check
# against it, and the check block below. See docs/org-setup.md.

locals {
  parent = "organizations/${var.org_id}"

  labels = {
    managed_by = "terraform"
    stack      = "1-org"
  }
}

# Independent of the guard, which reads a plan file and could be bypassed by running
# terraform directly.
check "org_writes_were_authorized" {
  assert {
    condition     = var.org_writes_allowed_for == var.org_id
    error_message = "This stack writes at organizations/${var.org_id}, but ORG_WRITES_ALLOWED_FOR is '${var.org_writes_allowed_for}'. Set them to the same numeric ID in config.env, and only in an organization that contains nothing you would miss."
  }
}

data "google_organization" "this" {
  organization = local.parent
}

# Same module as stage 1. The only difference is where it attaches.

module "org_policies" {
  source = "../../modules/org-policy-baseline"

  parent                    = local.parent
  allow_organization_parent = true
  customer_id               = var.customer_id
  allowed_locations         = ["in:us-locations"]
}

# A custom constraint is a CEL expression over a resource's own fields, evaluated on create and
# update. This one refuses any machine type outside the e2 family.

resource "google_org_policy_custom_constraint" "small_machines_only" {
  name         = "custom.labMachineTypesOnly"
  parent       = local.parent
  display_name = "Restrict VMs to e2 machine types"
  description  = "Lab cost control. e2 is the cheapest general-purpose family and includes the free-tier-eligible e2-micro."

  action_type    = "DENY"
  condition      = "!resource.machineType.contains('/machineTypes/e2-')"
  method_types   = ["CREATE", "UPDATE"]
  resource_types = ["compute.googleapis.com/Instance"]
}

resource "google_org_policy_policy" "small_machines_only" {
  name   = "${local.parent}/policies/${google_org_policy_custom_constraint.small_machines_only.name}"
  parent = local.parent

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

# Captures folders that do not exist yet, including ones another operator creates. A folder
# sink cannot.

resource "google_storage_bucket" "org_audit" {
  name     = "${var.prefix}-org-audit-${var.org_id}"
  project  = var.seed_project
  location = var.default_region
  labels   = local.labels

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition { age = 30 }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  lifecycle_rule {
    condition { age = var.audit_retention_days }
    action { type = "Delete" }
  }

  force_destroy = true
}

resource "google_logging_organization_sink" "audit" {
  name             = "${var.prefix}-org-audit"
  org_id           = var.org_id
  include_children = true
  description      = "Organization-wide audit export. Captures every folder and project, including ones created later (NIST AU-2, AU-12)."

  destination = "storage.googleapis.com/${google_storage_bucket.org_audit.name}"
  filter      = <<-FILTER
    logName:"logs/cloudaudit.googleapis.com"
    OR severity >= WARNING
  FILTER
}

resource "google_storage_bucket_iam_member" "org_sink_writer" {
  bucket = google_storage_bucket.org_audit.name
  role   = "roles/storage.objectCreator"
  member = google_logging_organization_sink.audit.writer_identity
}

# On creation an organization grants every domain user projectCreator and billing.creator at
# the org node, so any identity in the domain can create a project and attach billing.
#
# Revoking that also revokes it for you, since your own ability to create projects comes from
# the same grant. The admin identity needs projectCreator explicitly, not by domain membership,
# before this applies. AC-6

resource "google_organization_iam_member" "terraform_project_creator" {
  org_id = var.org_id
  role   = "roles/resourcemanager.projectCreator"
  member = "user:${data.google_client_openid_userinfo.caller.email}"
}

data "google_client_openid_userinfo" "caller" {}

resource "google_essential_contacts_contact" "org_security" {
  count = var.security_contact_email != null ? 1 : 0

  parent                              = local.parent
  email                               = var.security_contact_email
  language_tag                        = "en-US"
  notification_category_subscriptions = ["SECURITY", "TECHNICAL", "SUSPENSION"]
}
