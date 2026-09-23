variable "project_id" {
  description = "Shared VPC host project."
  type        = string
}

variable "folder_id" {
  description = "Folder the hierarchical firewall policy attaches to. Folder-scoped, never the org."
  type        = string
}

variable "prefix" {
  type = string
}

variable "region" {
  type = string
}

variable "subnets" {
  description = "Subnets to create. Secondary ranges are for GKE pods/services."
  type = map(object({
    cidr             = string
    secondary_ranges = optional(map(string), {})
  }))
  default = {
    app = {
      cidr = "10.10.0.0/20"
      secondary_ranges = {
        pods     = "10.20.0.0/16"
        services = "10.30.0.0/20"
      }
    }
    data = {
      cidr = "10.10.16.0/20"
    }
  }
}

variable "enable_nat" {
  description = "Create a Cloud NAT gateway for egress. Roughly $32/month for the gateway plus data processing, and it is the single largest line item in this repo. Off means private instances have no outbound internet at all."
  type        = bool
  default     = true
}

variable "enable_dns" {
  description = "Create a private DNS zone and Private Google Access DNS records."
  type        = bool
  default     = true
}

variable "private_zone_dns_name" {
  description = "Private DNS zone name. Must end with a dot."
  type        = string
  default     = "lab.internal."
}

variable "labels" {
  type    = map(string)
  default = {}
}
