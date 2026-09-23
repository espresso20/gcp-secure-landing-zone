variable "folder_id" {
  type = string
}

variable "seed_project" {
  type = string
}

variable "state_bucket" {
  description = "State bucket, needed to read stage 1's outputs."
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

variable "budget_amount" {
  description = "Per-project monthly alert threshold in USD."
  type        = number
  default     = 20
}
