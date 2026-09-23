output "network_id" {
  value = module.network.network_id
}

output "network_name" {
  value = module.network.network_name
}

output "subnets" {
  value = module.network.subnets
}

output "net_project" {
  value = local.net_project
}

output "dev_project" {
  value = local.service_projects.dev
}

output "sandbox_project" {
  value = local.service_projects.sandbox
}

output "disk_key" {
  value = google_kms_crypto_key.disk.id
}

output "storage_key" {
  value = google_kms_crypto_key.storage.id
}

output "region" {
  value = var.default_region
}
