# A purpose-built VPC rather than the auto-mode `default` network.
#
# The default network creates a subnet in every region with permissive firewall rules
# and no room for planned IP ranges. Using it is one of the most common findings in a
# GCP review, and fixing it later means rebuilding the cluster.

locals {
  # Stable index per environment so each gets non-overlapping ranges regardless of
  # iteration order.
  env_index = { for i, env in sort(tolist(var.environments)) : env => i }
}

resource "google_compute_network" "vpc" {
  name                    = "lumana-vpc"
  auto_create_subnetworks = false
  description             = "Lumana demo network"
}

resource "google_compute_subnetwork" "cluster" {
  for_each = var.environments

  name          = "lumana-${each.key}"
  network       = google_compute_network.vpc.id
  region        = var.region
  ip_cidr_range = cidrsubnet("10.10.0.0/16", 8, local.env_index[each.key])

  # VPC-native clusters allocate pod and service IPs from secondary ranges, so pods are
  # routable within the VPC rather than hidden behind per-node NAT.
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.${100 + local.env_index[each.key]}.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.${200 + local.env_index[each.key]}.0.0/20"
  }

  # Lets nodes without external IPs reach Google APIs. Costs nothing, unlike Cloud NAT.
  private_ip_google_access = true
}
