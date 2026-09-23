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

variable "default_zone" {
  type    = string
  default = "us-central1-a"
}

variable "machine_type" {
  description = "e2-micro is free-tier eligible in us-central1/us-west1/us-east1, one instance per month. Anything larger bills normally."
  type        = string
  default     = "e2-micro"
}

variable "iap_users" {
  description = "Members allowed to SSH via IAP, e.g. [\"user:you@example.com\"]. Empty means nobody can reach the VM, which is a valid but boring configuration."
  type        = list(string)
  default     = []
}
