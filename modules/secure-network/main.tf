# Shared VPC host network. Custom-mode, no external IPs, ingress via IAP only.
# NAT dominates the cost of this module; see variables.tf.

resource "google_compute_network" "vpc" {
  project                 = var.project_id
  name                    = "${var.prefix}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
  description             = "Shared VPC host network for the study playground."
}

resource "google_compute_shared_vpc_host_project" "host" {
  project = var.project_id
}

resource "google_compute_subnetwork" "subnets" {
  for_each = var.subnets

  project       = var.project_id
  name          = "${var.prefix}-${each.key}-${var.region}"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = each.value.cidr

  # Without this, an instance with no external IP cannot reach *.googleapis.com at all. SC-7
  private_ip_google_access = true

  dynamic "secondary_ip_range" {
    for_each = each.value.secondary_ranges
    content {
      range_name    = secondary_ip_range.key
      ip_cidr_range = secondary_ip_range.value
    }
  }

  # AU-12. Flow logs are the only thing here that scales with traffic; drop sampling to 0.1
  # if it shows up on a bill.
  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_router" "router" {
  count = var.enable_nat ? 1 : 0

  project = var.project_id
  name    = "${var.prefix}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  count = var.enable_nat ? 1 : 0

  project = var.project_id
  name    = "${var.prefix}-nat"
  router  = google_compute_router.router[0].name
  region  = var.region

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Hierarchical firewall policy.
#
# Evaluated before any VPC firewall rule in any project under the folder, and a project owner
# cannot override it. Priorities leave gaps so rules can be inserted without renumbering.

resource "google_compute_firewall_policy" "folder" {
  parent      = "folders/${var.folder_id}"
  short_name  = "${var.prefix}-hierarchical"
  description = "Folder-wide baseline. Applies beneath the study folder only (NIST SC-7, AC-17)."
}

# 35.235.240.0/20 is Google's fixed IAP forwarding range. AC-17
resource "google_compute_firewall_policy_rule" "allow_iap" {
  firewall_policy = google_compute_firewall_policy.folder.id
  priority        = 1000
  direction       = "INGRESS"
  action          = "allow"
  enable_logging  = true
  description     = "IAP TCP forwarding for SSH and RDP."

  match {
    src_ip_ranges = ["35.235.240.0/20"]
    layer4_configs {
      ip_protocol = "tcp"
      ports       = ["22", "3389"]
    }
  }
}

resource "google_compute_firewall_policy_rule" "allow_health_checks" {
  firewall_policy = google_compute_firewall_policy.folder.id
  priority        = 1100
  direction       = "INGRESS"
  action          = "allow"
  enable_logging  = true
  description     = "Google load balancer and health check ranges."

  match {
    src_ip_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
    layer4_configs {
      ip_protocol = "tcp"
    }
  }
}

resource "google_compute_firewall_policy_rule" "deny_all_ingress" {
  firewall_policy = google_compute_firewall_policy.folder.id
  priority        = 65000
  direction       = "INGRESS"
  action          = "deny"
  enable_logging  = true
  description     = "Default deny. Anything reaching this rule was not explicitly permitted."

  match {
    src_ip_ranges = ["0.0.0.0/0"]
    layer4_configs {
      ip_protocol = "all"
    }
  }
}

resource "google_compute_firewall_policy_association" "folder" {
  firewall_policy   = google_compute_firewall_policy.folder.id
  attachment_target = "folders/${var.folder_id}"
  name              = "${var.prefix}-hierarchical-assoc"
}

resource "google_dns_managed_zone" "private" {
  count = var.enable_dns ? 1 : 0

  project     = var.project_id
  name        = "${var.prefix}-private"
  dns_name    = var.private_zone_dns_name
  description = "Private zone for the study playground."
  labels      = var.labels

  visibility = "private"
  private_visibility_config {
    networks {
      network_url = google_compute_network.vpc.id
    }
  }
}

# DNS half of Private Google Access: sends *.googleapis.com to the restricted VIPs
# (199.36.153.4/30), which resolve only inside Google's network. Prerequisite for VPC-SC.
resource "google_dns_managed_zone" "private_googleapis" {
  count = var.enable_dns ? 1 : 0

  project     = var.project_id
  name        = "${var.prefix}-googleapis"
  dns_name    = "googleapis.com."
  description = "Routes Google API traffic over restricted VIPs rather than the internet."

  visibility = "private"
  private_visibility_config {
    networks {
      network_url = google_compute_network.vpc.id
    }
  }
}

resource "google_dns_record_set" "restricted_a" {
  count = var.enable_dns ? 1 : 0

  project      = var.project_id
  managed_zone = google_dns_managed_zone.private_googleapis[0].name
  name         = "restricted.googleapis.com."
  type         = "A"
  ttl          = 300
  rrdatas      = ["199.36.153.4", "199.36.153.5", "199.36.153.6", "199.36.153.7"]
}

resource "google_dns_record_set" "googleapis_cname" {
  count = var.enable_dns ? 1 : 0

  project      = var.project_id
  managed_zone = google_dns_managed_zone.private_googleapis[0].name
  name         = "*.googleapis.com."
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["restricted.googleapis.com."]
}
