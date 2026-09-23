terraform {
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.4"
    }
  }
  backend "gcs" {}
}

provider "google" {
  region                = var.default_region
  billing_project       = var.seed_project
  user_project_override = true
}
