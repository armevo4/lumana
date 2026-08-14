# The upstream API key lives in Secret Manager, not in a Kubernetes Secret manifest.
#
# It gets versioning, IAM-scoped access, audit logs of every read, and encryption with a
# Google-managed key. External Secrets Operator then projects it into the Kubernetes
# Secret that the brief requires, authenticating via Workload Identity with no key file
# anywhere in the chain.
#
# The rotating DATABASE credential deliberately does not live here — the rotator owns
# that Secret, and a second writer would fight it. See docs/SECRETS.md.

resource "google_secret_manager_secret" "tmdb_api_key" {
  secret_id = "tmdb-api-key"

  replication {
    auto {}
  }

  labels = {
    app = "lumana"
  }
}

# Only created when a key is supplied. This keeps `terraform apply` working on a fresh
# clone without the secret, rather than failing on a missing variable.
resource "google_secret_manager_secret_version" "tmdb_api_key" {
  count = var.tmdb_api_key != "" ? 1 : 0

  secret      = google_secret_manager_secret.tmdb_api_key.id
  secret_data = var.tmdb_api_key
}

# --- MongoDB admin password --------------------------------------------------------
#
# Generated here rather than chosen by a human, so no one ever knows it. External Secrets
# Operator projects it into the `mongodb-admin` Kubernetes Secret, which the database uses
# to initialise its root user and the rotator uses to manage application users.
#
# Note this password does NOT rotate. MONGO_INITDB_ROOT_PASSWORD only applies on first
# startup, so changing it after the database has initialised would lock the rotator out
# without any warning. Rotating it properly would mean a coordinated change inside
# MongoDB as well — out of scope, and called out here so the omission is visible.

resource "random_password" "mongodb_admin" {
  length  = 32
  special = false # avoids URI-encoding hazards in the connection string
}

resource "google_secret_manager_secret" "mongodb_admin_password" {
  secret_id = "mongodb-admin-password"

  replication {
    auto {}
  }

  labels = {
    app = "lumana"
  }
}

resource "google_secret_manager_secret_version" "mongodb_admin_password" {
  secret      = google_secret_manager_secret.mongodb_admin_password.id
  secret_data = random_password.mongodb_admin.result
}

# --- Identity for External Secrets Operator ---------------------------------------

resource "google_service_account" "external_secrets" {
  account_id   = "lumana-external-secrets"
  display_name = "External Secrets Operator"
  description  = "Reads the upstream API key from Secret Manager and projects it into Kubernetes"
}

# Scoped to this one secret, not project-wide secretAccessor. If this identity were ever
# compromised, the blast radius is a single read-only movie API key.
resource "google_secret_manager_secret_iam_member" "external_secrets" {
  for_each = {
    tmdb  = google_secret_manager_secret.tmdb_api_key.id
    mongo = google_secret_manager_secret.mongodb_admin_password.id
  }

  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.external_secrets.email}"
}

# Workload Identity binding: the Kubernetes ServiceAccount
# external-secrets/external-secrets may impersonate the GCP service account above. No
# key file is created, downloaded, or stored anywhere.
resource "google_service_account_iam_member" "external_secrets_workload_identity" {
  service_account_id = google_service_account.external_secrets.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[external-secrets/external-secrets]"
}
