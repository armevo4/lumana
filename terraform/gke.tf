resource "google_container_cluster" "this" {
  for_each = var.environments

  name     = "lumana-${each.key}"
  location = var.zone

  # Terraform manages an explicitly configured node pool, so the default one is removed
  # immediately after creation. A cluster cannot be created with zero node pools, hence
  # the create-then-discard dance.
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.cluster[each.key].id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Dataplane V2 (eBPF/Cilium). This is what actually ENFORCES the NetworkPolicies in
  # k8s/base/networkpolicy.yaml — without it they are accepted by the API server and
  # silently ignored, which is worse than not having them.
  datapath_provider = "ADVANCED_DATAPATH"

  release_channel {
    channel = "REGULAR"
  }

  # Pods receive a GCP identity without any service account key file. This is what lets
  # External Secrets Operator read from Secret Manager. See docs/SECRETS.md.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Kubernetes Secrets are encrypted in etcd with a KMS key rather than merely
  # base64-encoded. Relevant here because the rotating database credential lives in a
  # Secret rather than in Secret Manager.
  database_encryption {
    state    = "ENCRYPTED"
    key_name = google_kms_crypto_key.etcd.id
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.authorized_networks
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  # Private nodes are the production-correct choice, but they have no route to the
  # internet on their own — `private_ip_google_access` covers Google APIs only. This
  # application calls api.themoviedb.org, so private nodes REQUIRE Cloud NAT, which costs
  # roughly $32/month per gateway: more than every other resource here combined.
  #
  # So this is a variable rather than a hardcoded choice. Default is public nodes (free,
  # egress works); flip `enable_private_nodes` to true and nat.tf provisions the router
  # and gateway automatically. The security trade-off is deliberate and priced, not an
  # oversight.
  dynamic "private_cluster_config" {
    for_each = var.enable_private_nodes ? [1] : []
    content {
      enable_private_nodes    = true
      enable_private_endpoint = false
      master_ipv4_cidr_block  = "172.16.${local.env_index[each.key]}.0/28"
    }
  }

  # Without this, `terraform destroy` fails and the cluster keeps billing.
  deletion_protection = false

  # Cheaper than the default, which ships every pod log to Cloud Logging.
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  depends_on = [google_kms_crypto_key_iam_member.gke_etcd]
}

resource "google_container_node_pool" "primary" {
  for_each = var.environments

  name     = "primary"
  cluster  = google_container_cluster.this[each.key].id
  location = var.zone

  node_count = var.node_count

  node_config {
    machine_type = var.node_machine_type
    disk_size_gb = var.node_disk_size_gb
    disk_type    = "pd-balanced"
    spot         = var.use_spot_nodes

    service_account = google_service_account.gke_node.email
    # cloud-platform combined with a least-privilege service account is the documented
    # pattern: the SA's IAM roles are the real boundary, not the legacy scopes.
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    # Required for Workload Identity. Also blocks pods from reaching the legacy metadata
    # endpoint to steal the node's credentials.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    labels = {
      environment = each.key
    }

    tags = ["lumana", each.key]
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  lifecycle {
    ignore_changes = [node_config[0].labels]
  }
}
