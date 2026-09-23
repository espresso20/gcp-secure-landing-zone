variable "folder_id" {
  description = "Playground folder ID from stage 0. Bare numeric."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.folder_id))
    error_message = "folder_id must be the bare numeric ID, not folders/<id>."
  }
}

variable "seed_project" {
  description = "Seed project from stage 0."
  type        = string
}

variable "prefix" {
  type = string
}

variable "billing_account" {
  type = string
}

variable "default_region" {
  type    = string
  default = "us-central1"
}

variable "customer_id" {
  description = "Cloud Identity customer ID for domain-restricted sharing. Blank skips it."
  type        = string
  default     = null
}

variable "security_contact_email" {
  description = "Address Google notifies about security and privacy incidents for this folder (NIST IR-6). Blank skips Essential Contacts."
  type        = string
  default     = null
}

variable "audit_retention_days" {
  type    = number
  default = 365
}

variable "enforce_cmek" {
  type    = bool
  default = false
}

variable "boolean_policy_overrides" {
  description = "Relax a specific org policy constraint for an experiment, e.g. {\"compute.vmExternalIpAccess\" = false}."
  type        = map(bool)
  default     = {}
}
