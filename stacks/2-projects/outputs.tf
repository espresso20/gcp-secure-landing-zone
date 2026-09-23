output "net_project" {
  value = module.net.project_id
}

output "dev_project" {
  value = module.dev.project_id
}

output "sandbox_project" {
  value = module.sandbox.project_id
}

output "project_numbers" {
  description = "Needed to construct service agent identities."
  value = {
    net     = module.net.project_number
    dev     = module.dev.project_number
    sandbox = module.sandbox.project_number
  }
}

output "folder_id" {
  value = local.folder_id
}
