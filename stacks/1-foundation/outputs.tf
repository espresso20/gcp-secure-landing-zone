output "folder_id" {
  value = var.folder_id
}

output "policies_applied" {
  description = "Constraints enforced at the folder."
  value = {
    boolean = module.org_policies.boolean_constraints
    list    = module.org_policies.list_constraints
  }
}

output "audit_archive_bucket" {
  value = module.audit_logging.archive_bucket
}

output "asset_feed_topic" {
  value = module.audit_logging.asset_feed_topic
}
