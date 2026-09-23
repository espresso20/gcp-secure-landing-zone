output "folder_id" {
  description = "Playground folder, bare numeric ID. Every other stack attaches here or below."
  value       = google_folder.playground.folder_id
}

output "folder_name" {
  value = google_folder.playground.name
}

output "seed_project" {
  value = google_project.seed.project_id
}

output "state_bucket" {
  value = google_storage_bucket.state.name
}

# Consumed by `make bootstrap` to write these back into config.env, so the values are never
# transcribed by hand.
output "config_env" {
  description = "Shell fragment for config.env."
  value       = <<-EOT
    GCP_SEED_PROJECT=${google_project.seed.project_id}
    TF_VAR_state_bucket=${google_storage_bucket.state.name}
    TF_VAR_folder_id=${google_folder.playground.folder_id}
  EOT
}
