variable "org_id" {
  description = "Numeric organization ID."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.org_id))
    error_message = "org_id must be numeric. Run `make ids` to find it."
  }
}

variable "billing_account" {
  type = string
}

variable "prefix" {
  type = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,9}$", var.prefix))
    error_message = "prefix must be 3-10 lowercase alphanumerics starting with a letter, because it becomes part of globally unique project IDs."
  }
}

variable "folder_name" {
  description = "Display name of the playground folder."
  type        = string
  default     = "gcp-study-playground"
}

variable "default_region" {
  type    = string
  default = "us-central1"
}

variable "budget_amount" {
  type    = number
  default = 20
}
