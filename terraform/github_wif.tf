# Workload Identity Federation for GitHub Actions.
#
# This is the single best thing you can say about a CI pipeline: there is no service
# account key. GitHub Actions presents its OIDC token, GCP verifies it came from this
# specific repository, and issues a short-lived access token. Nothing long-lived exists
# to leak, rotate, or accidentally commit.
#
# The alternative — a service account JSON key in a GitHub secret — is a permanent
# credential sitting in a third party's storage. It is still extremely common, and it is
# what the attribute condition below exists to make unnecessary.

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions"
  description               = "Keyless OIDC federation for GitHub Actions"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.actor"      = "assertion.actor"
  }

  # Without this condition, ANY GitHub repository on the internet could present a token
  # and assume this identity. It is the security boundary of the whole arrangement, and
  # omitting it is the classic WIF misconfiguration.
  attribute_condition = "assertion.repository == '${var.github_repository}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "github_actions" {
  account_id   = "lumana-github-actions"
  display_name = "GitHub Actions CI"
  description  = "Builds and pushes images; deploys to GKE"
}

locals {
  github_actions_roles = [
    # Push images. Not `admin`: CI never needs to delete a repository.
    "roles/artifactregistry.writer",
    # Deploy workloads. Not `container.admin`: CI never needs to create or destroy
    # clusters — that is Terraform's job, run by a human.
    "roles/container.developer",
  ]
}

resource "google_project_iam_member" "github_actions" {
  for_each = toset(local.github_actions_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}

resource "google_service_account_iam_member" "github_actions_workload_identity" {
  service_account_id = google_service_account.github_actions.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}
