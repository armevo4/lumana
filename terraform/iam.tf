# A dedicated, least-privilege service account for GKE nodes.
#
# This matters more than it looks. If you omit `service_account` on a node pool, GKE uses
# the *default Compute Engine service account*, which carries the project-wide Editor
# role. Every pod on that node can then reach the metadata server and act as an Editor on
# the whole project. It is one of the most common real findings in a GCP security review,
# and it is fixed by the eight lines below.
#
# These five roles are the documented minimum for a functioning GKE node.

resource "google_service_account" "gke_node" {
  account_id   = "lumana-gke-node"
  display_name = "Lumana GKE node service account"
  description  = "Least-privilege identity for GKE nodes; replaces the default Compute Engine SA"
}

locals {
  gke_node_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    # Pull images from Artifact Registry. Read-only: nodes never push.
    "roles/artifactregistry.reader",
  ]
}

resource "google_project_iam_member" "gke_node" {
  for_each = toset(local.gke_node_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.gke_node.email}"
}
