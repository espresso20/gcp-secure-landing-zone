variable "parent" {
  description = "Resource to attach policies to. MUST be folders/<id> or projects/<id> — never organizations/<id>."
  type        = string

  validation {
    condition     = can(regex("^(folders|projects)/", var.parent))
    error_message = "parent must start with folders/ or projects/. Attaching org policy at the organization node would make every sibling folder inherit it, which this repo exists to prevent."
  }
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
