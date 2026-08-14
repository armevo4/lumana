terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.12"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # State is local for this exercise. A real deployment would use a GCS backend with
  # state locking, which is commented out below rather than enabled, because creating
  # the bucket is a chicken-and-egg problem on a fresh project.
  #
  # backend "gcs" {
  #   bucket = "lumana-tfstate"
  #   prefix = "gke"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
