output "network_id" {
  value = google_compute_network.vpc.id
}

output "network_name" {
  value = google_compute_network.vpc.name
}

output "subnets" {
  description = "Subnet self-links keyed by the name given in var.subnets."
  value       = { for k, v in google_compute_subnetwork.subnets : k => v.self_link }
}

output "host_project" {
  value = google_compute_shared_vpc_host_project.host.project
}

output "firewall_policy_id" {
  value = google_compute_firewall_policy.folder.id
}

output "nat_enabled" {
  value = var.enable_nat
}
