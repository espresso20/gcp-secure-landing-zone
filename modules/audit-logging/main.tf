# Audit log collection for the playground folder — the AU control family.
#
# Two destinations, because they answer different questions:
#
#   Log bucket (Cloud Logging)  — queryable. This is where you actually investigate something.
#                                 AU-6 (review and analysis), AU-7 (reduction and reporting).
#   GCS archive                 — cheap, immutable-ish, long retention. This is the copy that
#                                 survives someone deleting the log bucket. AU-9, AU-11.
#
# The sink is attached to the FOLDER with include_children, not to the organization. A folder
# sink sees every project beneath it and nothing beside it, which is exactly the boundary this
# repo is built around.
#
# Cost note: at lab volumes this is cents per month. GCS Standard is $0.020/GiB and the
# lifecycle rule moves objects to Nearline at 30 days and Coldline at 90.

locals {
  archive_bucket_name = "${var.prefix}-audit-archive-${var.folder_id}"
  log_bucket_id       = "${var.prefix}-audit-logs"
}

# --- Queryable retention -------------------------------------------------------------------

resource "google_logging_project_bucket_config" "audit" {
  project        = var.project_id
  location       = var.region
  retention_days = var.retention_days
  bucket_id      = local.log_bucket_id
  description    = "Folder-scoped audit log retention for the study playground (NIST AU-11)."

  # Deliberately not locked. `locked = true` is permanent and would make this bucket outlive
  # every attempt to tear the lab down.
  locked = false
}

# --- Long-term archive ----------------------------------------------------------------------

resource "google_storage_bucket" "audit_archive" {
  name     = local.archive_bucket_name
  project  = var.project_id
  location = var.region
  labels   = var.labels

  # AC-3 — IAM is the only access path. Matches the storage.uniformBucketLevelAccess policy.
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # AU-9 — recover an object that was overwritten or deleted.
  versioning {
    enabled = true
  }

  # AU-11 held cheaply.
  lifecycle_rule {
    condition { age = 30 }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  lifecycle_rule {
    condition { age = 90 }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }

  lifecycle_rule {
    condition { age = var.retention_days }
    action { type = "Delete" }
  }

  # Only present when explicitly asked for — see variables.tf for why this is a trap in a lab.
  dynamic "retention_policy" {
    for_each = var.lock_retention ? [1] : []
    content {
      is_locked        = true
      retention_period = var.retention_days * 24 * 60 * 60
    }
  }

  # force_destroy tracks the lock: a locked bucket cannot be force-destroyed anyway, and an
  # unlocked lab bucket should not block `make down`.
  force_destroy = !var.lock_retention
}

# --- The sink itself -------------------------------------------------------------------------

resource "google_logging_folder_sink" "audit_archive" {
  name             = "${var.prefix}-audit-to-gcs"
  folder           = var.folder_id
  include_children = true
  description      = "Aggregated audit export for every project under the study folder (NIST AU-2, AU-12)."

  destination = "storage.googleapis.com/${google_storage_bucket.audit_archive.name}"
  filter      = var.log_filter
}

# The sink writes as its own service identity, which does not exist until the sink does.
resource "google_storage_bucket_iam_member" "sink_writer" {
  bucket = google_storage_bucket.audit_archive.name
  role   = "roles/storage.objectCreator"
  member = google_logging_folder_sink.audit_archive.writer_identity
}

# --- Change detection --------------------------------------------------------------------------
#
# CM-3 / SI-4 — an asset feed emits a message on every resource and IAM policy change beneath
# the folder. Folder-scoped, so it observes this subtree only.

resource "google_pubsub_topic" "asset_changes" {
  name    = "${var.prefix}-asset-changes"
  project = var.project_id
  labels  = var.labels
}

resource "google_cloud_asset_folder_feed" "changes" {
  billing_project = var.project_id
  folder          = var.folder_id
  feed_id         = "${var.prefix}-asset-changes"
  content_type    = "RESOURCE"

  asset_types = [
    "compute.googleapis.com/Instance",
    "compute.googleapis.com/Firewall",
    "compute.googleapis.com/Network",
    "storage.googleapis.com/Bucket",
    "iam.googleapis.com/ServiceAccount",
    "cloudresourcemanager.googleapis.com/Project",
  ]

  feed_output_config {
    pubsub_destination {
      topic = google_pubsub_topic.asset_changes.id
    }
  }

  depends_on = [google_pubsub_topic_iam_member.asset_publisher]
}

# The Cloud Asset service agent needs publish rights before the feed will validate.
data "google_project" "host" {
  project_id = var.project_id
}

resource "google_pubsub_topic_iam_member" "asset_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.asset_changes.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:service-${data.google_project.host.number}@gcp-sa-cloudasset.iam.gserviceaccount.com"
}
