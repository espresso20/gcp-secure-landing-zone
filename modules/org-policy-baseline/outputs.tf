output "boolean_constraints" {
  description = "Boolean constraints enforced at this parent, and their enforcement state."
  value       = local.boolean_policies
}

output "list_constraints" {
  description = "List constraint names applied at this parent."
  value       = sort(keys(local.list_policies))
}

output "parent" {
  description = "Node these policies attach to."
  value       = var.parent
}
