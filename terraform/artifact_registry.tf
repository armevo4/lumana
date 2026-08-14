resource "google_artifact_registry_repository" "docker" {
  location      = var.region
  repository_id = "lumana"
  format        = "DOCKER"
  description   = "Container images for the Lumana API proxy and credential rotator"

  # Keep storage costs at zero without manual pruning: untagged images are garbage, and
  # old tagged builds are not worth paying for after a month.
  cleanup_policies {
    id     = "delete-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "604800s" # 7 days
    }
  }

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }
}
