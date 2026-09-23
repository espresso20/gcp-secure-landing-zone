variable "name" {
  description = "Short project name, e.g. \"net\" or \"dev\". Combined with the prefix and a suffix to form the project ID."
  type        = string
}

variable "prefix" {
  description = "Organization-wide prefix, shared by every project this repo creates."
  type        = string
}

variable "folder_id" {
  description = "Parent folder, bare numeric ID. Never an organization."
  type        = string
}

variable "billing_account" {
  type = string
}

variable "activate_apis" {
  description = "APIs to enable. Keep this tight: CM-7 least functionality, and every enabled API is attack surface you have to reason about."
  type        = list(string)
  default     = []
}

variable "enable_data_access_logs" {
  description = "Turn on DATA_READ/DATA_WRITE audit logs for all services. NIST AU-2/AU-12 want this; it is off by default in GCP because it is chatty. At lab volume the cost is negligible."
  type        = bool
  default     = true
}

variable "data_access_log_exemptions" {
  description = "Members exempted from data access logging. Normally empty, since an exemption is a hole in AU-12 and should be justified in the control mapping."
  type        = list(string)
  default     = []
}

variable "budget_amount" {
  description = "Monthly budget alert threshold in USD. Zero disables the budget."
  type        = number
  default     = 0
}

variable "budget_billing_project" {
  description = "Project with the Billing Budget API enabled, used to create the budget. Usually the seed project."
  type        = string
  default     = null
}

variable "labels" {
  type    = map(string)
  default = {}
}

variable "shared_vpc_host_project" {
  description = "Attach this project as a Shared VPC service project of the given host. Null to skip."
  type        = string
  default     = null
}

variable "random_suffix" {
  description = "Append a random suffix to the project ID. Project IDs are globally unique and permanently burned on delete, so a lab you rebuild repeatedly needs this."
  type        = bool
  default     = true
}
