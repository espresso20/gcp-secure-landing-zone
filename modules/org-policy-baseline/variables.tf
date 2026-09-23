variable "parent" {
  description = "Resource to attach policies to: folders/<id>, projects/<id>, or — only with allow_organization_parent — organizations/<id>."
  type        = string

  validation {
    condition     = can(regex("^(folders|projects|organizations)/[0-9]+$", var.parent))
    error_message = "parent must be folders/<id>, projects/<id> or organizations/<id>, with a numeric ID."
  }

  # The org node is reachable, but never by accident. Two things have to be true: this module
  # has to be told explicitly, and scripts/guard.sh has to have been given the matching org ID.
  # Neither alone is enough, and they are set in different files by different mechanisms, so a
  # single careless edit cannot open both.
  validation {
    condition     = !startswith(var.parent, "organizations/") || var.allow_organization_parent
    error_message = "parent is an organization, but allow_organization_parent is false. Attaching org policy at the organization node makes every folder in that organization inherit it — including anything you did not build. Set this only in an organization that contains nothing you would miss, and see docs/org-setup.md."
  }
}

variable "allow_organization_parent" {
  description = "Permit an organizations/<id> parent. False everywhere except the dedicated lab org — see docs/architecture.md, \"Running at the organization level\"."
  type        = bool
  default     = false
}

variable "customer_id" {
  description = "Cloud Identity customer ID (C0xxxxxxx) for domain-restricted sharing. Null disables that one policy."
  type        = string
  default     = null
}

variable "allowed_locations" {
  description = "Value groups for gcp.resourceLocations. Empty list disables the location constraint."
  type        = list(string)
  default     = ["in:us-locations"]
}

variable "enforce_cmek" {
  description = "Require CMEK on supported services. Off by default: it makes every ad-hoc bucket and disk fail until a key exists, which is a poor fit for a playground."
  type        = bool
  default     = false
}

variable "boolean_policy_overrides" {
  description = "Per-constraint escape hatch, e.g. { \"compute.vmExternalIpAccess\" = false } to relax one policy for an experiment without editing the module."
  type        = map(bool)
  default     = {}
}
