output "archive_bucket" {
  description = "GCS bucket holding the long-term audit archive."
  value       = google_storage_bucket.audit_archive.name
}

output "log_bucket_id" {
  description = "Cloud Logging bucket ID for queryable retention."
  value       = google_logging_project_bucket_config.audit.bucket_id
}

output "sink_writer_identity" {
  description = "Service identity the folder sink writes as."
  value       = google_logging_folder_sink.audit_archive.writer_identity
}

output "asset_feed_topic" {
  description = "Pub/Sub topic receiving resource change notifications."
  value       = google_pubsub_topic.asset_changes.id
}
