# Folder-scoped audit collection. AU control family.
#
# Two destinations: a Cloud Logging bucket you can query (AU-6, AU-7) and a GCS archive that
# survives someone deleting the log bucket (AU-9, AU-11).
#
# The sink attaches to the folder with include_children, so it sees every project beneath it
# and nothing beside it. Cents per month at lab volume.

locals {
  archive_bucket_name = "${var.prefix}-audit-archive-${var.folder_id}"
  log_bucket_id       = "${var.prefix}-audit-logs"
}

resource "google_logging_project_bucket_config" "audit" {
  project        = var.project_id
  location       = var.region
  retention_days = var.retention_days
  bucket_id      = local.log_bucket_id
  description    = "Folder-scoped audit log retention for the study playground (NIST AU-11)."

  # `locked = true` is permanent and would outlive every attempt to tear the lab down.
  locked = false
}

resource "google_storage_bucket" "audit_archive" {
  name     = local.archive_bucket_name
  project  = var.project_id
  location = var.region
  labels   = var.labels

  # AC-3
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # AU-9: recover an object that was overwritten or deleted.
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

  # Only present when explicitly asked for. See variables.tf for why this is a trap in a lab.
  dynamic "retention_policy" {
    for_each = var.lock_retention ? [1] : []
    content {
      is_locked        = true
      retention_period = var.retention_days * 24 * 60 * 60
    }
  }

  # A locked bucket cannot be force-destroyed anyway.
  force_destroy = !var.lock_retention
}

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

# Asset feed: a message on every resource and IAM change beneath the folder. CM-3, SI-4
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
