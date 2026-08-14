output "cluster_names" {
  description = "Created GKE clusters."
  value       = { for env, c in google_container_cluster.this : env => c.name }
}

output "get_credentials_commands" {
  description = "Run these to add each cluster to your kubeconfig."
  value = {
    for env, c in google_container_cluster.this :
    env => "gcloud container clusters get-credentials ${c.name} --zone ${var.zone} --project ${var.project_id}"
  }
}

output "artifact_registry_url" {
  description = "Docker repository to tag and push images to."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.docker.repository_id}"
}

output "external_secrets_service_account" {
  description = "Annotate the external-secrets Kubernetes ServiceAccount with this."
  value       = google_service_account.external_secrets.email
}

output "github_actions_service_account" {
  description = "service_account input for google-github-actions/auth."
  value       = google_service_account.github_actions.email
}

output "workload_identity_provider" {
  description = "workload_identity_provider input for google-github-actions/auth."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "estimated_hourly_cost_usd" {
  description = "Rough running cost while these clusters exist. Destroy when idle."
  value = format(
    "~$%.2f/hour (%d clusters, %d x %s %s nodes each, plus 1 load balancer per cluster)",
    (length(var.environments) - 1) * 0.10                                               # management fee, first cluster is free tier
    + length(var.environments) * var.node_count * (var.use_spot_nodes ? 0.010 : 0.0335) # nodes
    + length(var.environments) * 0.025                                                  # load balancers
    + (var.enable_private_nodes ? length(var.environments) * 0.044 : 0),                # Cloud NAT
    length(var.environments),
    var.node_count,
    var.node_machine_type,
    var.use_spot_nodes ? "Spot" : "on-demand",
  )
}
