# Stage 1-org — organization-level baseline. LAB ORGANIZATION ONLY.
#
# Everything here writes at the organization node, which is precisely what the rest of this
# repo is built to prevent. It exists because three capabilities have no folder-scoped form at
# all, and they are the interesting ones:
#
#   * Custom org policy constraints. Defined only at the organization. Without them you are
#     limited to the constraints Google ships.
#   * Organization-wide aggregated log sinks. A folder sink sees its own subtree; only an org
#     sink sees folders created later by someone else.
#   * Organization IAM, including the default grants every new domain user receives.
#
# Running this in an organization that already holds workloads applies these constraints to them
# immediately, by inheritance. That is not a risk to manage — it is the documented behaviour of
# organization policy.
#
# Three independent things must agree before this applies:
#
#   1. config.env sets ORG_WRITES_ALLOWED_FOR to this organization's numeric ID
#   2. scripts/guard.sh sees that value and permits org-node writes for that org alone
#   3. the check block below confirms Terraform was handed the same ID
#
# They live in different files and are set by different mechanisms, so no single careless edit
# opens all three. See docs/org-setup.md for standing up an organization this is safe in.

locals {
  parent = "organizations/${var.org_id}"

  labels = {
    managed_by = "terraform"
    stack      = "1-org"
  }
}

# Terraform's own refusal, independent of the guard. Belt and braces: the guard reads a plan
# file and could in principle be bypassed by running terraform directly; this cannot.
check "org_writes_were_authorized" {
  assert {
    condition     = var.org_writes_allowed_for == var.org_id
    error_message = "This stack writes at organizations/${var.org_id}, but ORG_WRITES_ALLOWED_FOR is '${var.org_writes_allowed_for}'. Set them to the same numeric ID in config.env, and only in an organization that contains nothing you would miss."
  }
}

data "google_organization" "this" {
  organization = local.parent
}

# --- Organization-wide policy -------------------------------------------------------------
#
# Same module as the folder-scoped stage. The only difference is where it attaches, which is
# the entire point of the comparison this repo is meant to support.

module "org_policies" {
  source = "../../modules/org-policy-baseline"

  parent                    = local.parent
  allow_organization_parent = true
  customer_id               = var.customer_id
  allowed_locations         = ["in:us-locations"]
}

# --- Custom constraints ----------------------------------------------------------------------
#
# The capability the folder-scoped variant cannot have at all. A custom constraint is a CEL
# expression over a resource's own fields, evaluated at create and update time.
#
# This one refuses any VM whose machine type is not e2-*, which is a crude but genuine cost
# control and demonstrates the shape: METHOD_TYPES, a resource type, and a condition.

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

# --- Organization-wide audit export ------------------------------------------------------------
#
# Unlike a folder sink, this captures folders that do not exist yet — including ones created by
# someone else. In an org with more than one operator that difference is the whole argument for
# doing this at the organization.

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

# --- Organization IAM ------------------------------------------------------------------------------
#
# AC-6. When an organization is created, every user in the domain is granted
# roles/resourcemanager.projectCreator and roles/billing.creator at the org node. That is
# convenient for a first-day org and wrong for anything past it: any identity in the domain can
# create a project and attach billing to it.
#
# Removing those grants is an organization-level IAM change with no folder-scoped equivalent.
# It is also destructive in a way worth understanding before you run it — including for you,
# since your own ability to create projects comes from exactly this grant. The Terraform admin
# identity must hold projectCreator explicitly, not by domain membership, before this applies.

resource "google_organization_iam_member" "terraform_project_creator" {
  org_id = var.org_id
  role   = "roles/resourcemanager.projectCreator"
  member = "user:${data.google_client_openid_userinfo.caller.email}"
}

data "google_client_openid_userinfo" "caller" {}

# --- Incident routing ------------------------------------------------------------------------------

resource "google_essential_contacts_contact" "org_security" {
  count = var.security_contact_email != null ? 1 : 0

  parent                              = local.parent
  email                               = var.security_contact_email
  language_tag                        = "en-US"
  notification_category_subscriptions = ["SECURITY", "TECHNICAL", "SUSPENSION"]
}
