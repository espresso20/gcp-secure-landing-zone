variable "seed_project" {
  type = string
}

variable "state_bucket" {
  type = string
}

variable "prefix" {
  type = string
}

variable "default_region" {
  type    = string
  default = "us-central1"
}

variable "enable_nat" {
  description = "Cloud NAT gateway. The most expensive single resource in this repo, roughly $32/month if left running. `make lab-down` destroys this whole stack for exactly that reason."
  type        = bool
  default     = true
}

variable "enable_dns" {
  type    = bool
  default = true
}
