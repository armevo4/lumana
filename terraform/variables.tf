variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "Region for regional resources (Artifact Registry, subnets)."
  type        = string
  default     = "europe-west1"
}

variable "zone" {
  description = "Zone for the GKE clusters. Zonal rather than regional: a regional cluster runs a control plane in three zones and triples the node count, which this demo does not need."
  type        = string
  default     = "europe-west1-b"
}

variable "environments" {
  description = "Environments to create a cluster for. Dev is deliberately absent — it runs on kind locally."
  type        = set(string)
  default     = ["staging", "production"]
}

variable "node_machine_type" {
  description = "Node size. e2-medium (4GB) rather than e2-small: GKE system pods consume 600-700MB per node, and a Pending pod mid-demo costs more than the price difference."
  type        = string
  default     = "e2-medium"
}

variable "node_count" {
  description = "Nodes per cluster."
  type        = number
  default     = 2
}

variable "node_disk_size_gb" {
  description = "Node boot disk. The GKE default is 100GB, which is ~$10/month per node of pure waste for this workload."
  type        = number
  default     = 30
}

variable "use_spot_nodes" {
  description = "Spot nodes are ~70% cheaper but can be preempted with 30 seconds' notice. Keep true while building; set false before recording, since losing the single MongoDB replica mid-demo would break the zero-downtime run."
  type        = bool
  default     = true
}

variable "enable_private_nodes" {
  description = "Private nodes have no external IP, which is the production-correct posture — but they cannot reach the upstream API without Cloud NAT (~$32/month per gateway). Setting this true automatically provisions the NAT in nat.tf. Default false to keep the demo cheap."
  type        = bool
  default     = false
}

variable "authorized_networks" {
  description = "CIDRs allowed to reach the Kubernetes control plane. Defaults to open because a locked-down default silently breaks kubectl from a changing home IP; set this to your own address for a real deployment."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = [{
    cidr_block   = "0.0.0.0/0"
    display_name = "all (demo only - restrict this)"
  }]
}

variable "github_repository" {
  description = "owner/repo allowed to authenticate via Workload Identity Federation. Scoping to a single repository is what stops any other repo from minting tokens for this project."
  type        = string
  default     = "armevo4/lumana"
}

variable "tmdb_api_key" {
  description = "Upstream API key, stored in Secret Manager. Supply via TF_VAR_tmdb_api_key or a gitignored tfvars file - never commit it."
  type        = string
  sensitive   = true
  default     = ""
}
