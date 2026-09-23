variable "org_id" {
  description = "Numeric organization ID. This stack writes at this organization's own node."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.org_id))
    error_message = "org_id must be numeric."
  }
}

variable "org_writes_allowed_for" {
  description = "Value of ORG_WRITES_ALLOWED_FOR from config.env, passed in so Terraform can refuse a mismatch on its own rather than relying solely on the guard."
  type        = string
  default     = ""
}

variable "seed_project" {
  type = string
}

variable "prefix" {
  type = string
}

variable "default_region" {
  type    = string
  default = "us-central1"
}

variable "customer_id" {
  type    = string
  default = null
}

variable "security_contact_email" {
  type    = string
  default = null
}

variable "audit_retention_days" {
  type    = number
  default = 365
}
