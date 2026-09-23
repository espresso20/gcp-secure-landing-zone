output "instance_name" {
  value = google_compute_instance.lab.name
}

output "ssh_command" {
  description = "There is no public IP; this is the only way in."
  value       = "gcloud compute ssh ${google_compute_instance.lab.name} --zone ${var.default_zone} --tunnel-through-iap --project ${local.dev_project}"
}

output "bucket" {
  value = google_storage_bucket.data.name
}

output "service_account" {
  value = google_service_account.vm.email
}
