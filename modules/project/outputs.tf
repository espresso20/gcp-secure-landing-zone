output "project_id" {
  value = google_project.this.project_id
}

output "project_number" {
  description = "Numeric project number. Service agent email addresses are built from this, not the project ID."
  value       = google_project.this.number
}

output "enabled_apis" {
  value = sort(var.activate_apis)
}
