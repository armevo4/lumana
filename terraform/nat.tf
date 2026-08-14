# Cloud NAT — only created when private nodes are enabled.
#
# Private nodes have no external IP and therefore no route to the internet. This
# application must reach api.themoviedb.org, so without NAT every upstream call fails
# with a connection timeout that looks like an application bug rather than a network one.
#
# Left off by default purely on cost: ~$0.044/hour per gateway, about $32/month, plus
# data processing. For a demo that runs for hours, public nodes are the sane trade.

resource "google_compute_router" "nat" {
  for_each = var.enable_private_nodes ? var.environments : []

  name    = "lumana-${each.key}-router"
  network = google_compute_network.vpc.id
  region  = var.region
}

resource "google_compute_router_nat" "nat" {
  for_each = var.enable_private_nodes ? var.environments : []

  name   = "lumana-${each.key}-nat"
  router = google_compute_router.nat[each.key].name
  region = var.region

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
