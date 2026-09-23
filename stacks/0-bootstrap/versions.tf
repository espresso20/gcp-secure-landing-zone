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

  # Deliberately no backend block.
  #
  # This stack creates the bucket every other stack stores state in, so on the first run there
  # is nowhere remote to put its own state. It runs on local state, and `make bootstrap-migrate`
  # moves it into the bucket afterwards. That chicken-and-egg step is a real part of the
  # Enterprise Foundation Blueprint and a fair exam question.
}

provider "google" {
  region = var.default_region
}
