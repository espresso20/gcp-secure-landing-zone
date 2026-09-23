output "org_id" {
  value = var.org_id
}

output "org_domain" {
  description = "The organization's display name, which is its Cloud Identity primary domain."
  value       = data.google_organization.this.domain
}

output "custom_constraint" {
  description = "Custom constraint name. The capability folder-scoped mode cannot have."
  value       = google_org_policy_custom_constraint.small_machines_only.name
}

output "org_audit_bucket" {
  value = google_storage_bucket.org_audit.name
}

output "org_sink_writer_identity" {
  value = google_logging_organization_sink.audit.writer_identity
}

output "policies_applied" {
  value = {
    boolean = module.org_policies.boolean_constraints
    list    = module.org_policies.list_constraints
  }
}
