variable "folder_id" {
  description = "Folder whose logs are collected, as a bare numeric ID."
  type        = string
}

variable "project_id" {
  description = "Project that owns the log sink destination bucket."
  type        = string
}

variable "region" {
  description = "Region for the log archive bucket. Single-region keeps cost and data residency predictable."
  type        = string
}

variable "prefix" {
  description = "Name prefix for created resources."
  type        = string
}

variable "retention_days" {
  description = "Archive retention. NIST AU-11 has no fixed number; FedRAMP Moderate practice is 1 year online plus 2 years offline. 365 is the online half."
  type        = number
  default     = 365

  validation {
    condition     = var.retention_days >= 30
    error_message = "retention_days below 30 defeats the point of the archive."
  }
}

variable "lock_retention" {
  description = "Apply a GCS retention LOCK to the archive bucket. AU-9 (protection of audit information) effectively wants this. It is IRREVERSIBLE — a locked bucket cannot be deleted until every object ages out, which will strand `make destroy`. Off by default for that reason."
  type        = bool
  default     = false
}

variable "log_filter" {
  description = "Sink filter. The default takes admin activity, system events, data access and policy denials, and drops the high-volume, low-value noise."
  type        = string
  default     = <<-FILTER
    logName:"logs/cloudaudit.googleapis.com"
    OR severity >= WARNING
  FILTER
}

variable "labels" {
  type    = map(string)
  default = {}
}
