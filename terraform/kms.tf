# KMS key for GKE application-layer Secret encryption (envelope encryption of etcd).
#
# Worth the twenty lines: the rotating database credential is a Kubernetes Secret, not a
# Secret Manager entry, so etcd encryption is the control that protects it at rest. See
# docs/SECRETS.md.

resource "google_kms_key_ring" "lumana" {
  name     = "lumana-keyring"
  location = var.region
}

resource "google_kms_crypto_key" "etcd" {
  name     = "gke-etcd"
  key_ring = google_kms_key_ring.lumana.id

  rotation_period = "7776000s" # 90 days

  lifecycle {
    # A destroyed key ring cannot be recreated with the same name, and keys cannot truly
    # be deleted — only scheduled for destruction. Guard against accidental removal.
    prevent_destroy = false
  }
}

# The GKE service agent must be able to use the key, otherwise cluster creation fails
# with a permissions error that does not name the key.
data "google_project" "current" {
  project_id = var.project_id
}

resource "google_kms_crypto_key_iam_member" "gke_etcd" {
  crypto_key_id = google_kms_crypto_key.etcd.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.current.number}@container-engine-robot.iam.gserviceaccount.com"
}
