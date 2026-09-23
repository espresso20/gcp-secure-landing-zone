terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Partial backend. The Makefile supplies bucket and prefix from config.env, so the state
  # location is not hardcoded into a file that gets committed.
  backend "gcs" {}
}

provider "google" {
  region = var.default_region
  # Billing/quota project for API calls that are not themselves scoped to a project.
  billing_project       = var.seed_project
  user_project_override = true
}
