# Stage 4: one hardened instance and one encrypted bucket. Destroyable tier.
#
# Exists to exercise the controls from stages 1 and 3 against something real. If a resource
# here fails to create, the org policy baseline is working; read the error before relaxing it.

data "terraform_remote_state" "network" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "3-network"
  }
}

locals {
  net         = data.terraform_remote_state.network.outputs
  dev_project = local.net.dev_project

  labels = {
    managed_by = "terraform"
    stack      = "4-workload"
    purpose    = "study-playground"
  }
}

# The default Compute Engine service account holds Editor on the whole project. Start from a
# dedicated account with nothing attached and add roles when something fails. AC-6

resource "google_service_account" "vm" {
  project      = local.dev_project
  account_id   = "${var.prefix}-lab-vm"
  display_name = "Lab instance identity"
  description  = "Deliberately unprivileged. Grant roles as experiments require them."
}

# AU-12: the instance can write its own logs and metrics, and nothing else.
resource "google_project_iam_member" "vm_logging" {
  project = local.dev_project
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_project_iam_member" "vm_metrics" {
  project = local.dev_project
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.vm.email}"
}

# Service agents encrypt on your behalf and need decrypt rights on the key. Without these the
# disk fails to create with an error that never mentions KMS.

data "google_project" "dev" {
  project_id = local.dev_project
}

resource "google_kms_crypto_key_iam_member" "compute_agent" {
  crypto_key_id = local.net.disk_key
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.dev.number}@compute-system.iam.gserviceaccount.com"
}

resource "google_kms_crypto_key_iam_member" "storage_agent" {
  crypto_key_id = local.net.storage_key
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.dev.number}@gs-project-accounts.iam.gserviceaccount.com"
}

resource "google_compute_instance" "lab" {
  project      = local.dev_project
  name         = "${var.prefix}-lab-01"
  machine_type = var.machine_type
  zone         = var.default_zone
  labels       = local.labels

  boot_disk {
    initialize_params {
      # Shielded-capable image; org policy rejects anything else.
      image = "debian-cloud/debian-12"
      size  = 10
      type  = "pd-balanced"
    }
    # SC-28
    kms_key_self_link = local.net.disk_key
  }

  network_interface {
    subnetwork = local.net.subnets["app"]
    # No access_config block, so no public IP. Org policy is the backstop if one is added.
  }

  # Required by compute.requireShieldedVm. SI-7
  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  service_account {
    email = google_service_account.vm.email
    # Constrain with IAM, not scopes. Scopes predate fine-grained IAM.
    scopes = ["cloud-platform"]
  }

  metadata = {
    # SSH keys come from IAM identity. AC-2, IA-2
    enable-oslogin = "TRUE"
    # AC-17
    serial-port-enable = "FALSE"
  }

  # A stopped instance costs only its disk.
  desired_status = "RUNNING"

  depends_on = [google_kms_crypto_key_iam_member.compute_agent]
}

# No public IP and no rule permitting the internet, so IAP is the only path in. AC-17
#
#   gcloud compute ssh <name> --zone <zone> --tunnel-through-iap --project <dev project>

resource "google_iap_tunnel_instance_iam_member" "ssh" {
  for_each = toset(var.iap_users)

  project  = local.dev_project
  zone     = var.default_zone
  instance = google_compute_instance.lab.name
  role     = "roles/iap.tunnelResourceAccessor"
  member   = each.value
}

resource "google_project_iam_member" "os_login" {
  for_each = toset(var.iap_users)

  project = local.dev_project
  role    = "roles/compute.osLogin"
  member  = each.value
}

resource "google_storage_bucket" "data" {
  name     = "${var.prefix}-lab-data-${data.google_project.dev.number}"
  project  = local.dev_project
  location = var.default_region
  labels   = local.labels

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  encryption {
    default_kms_key_name = local.net.storage_key
  }

  # Lab data.
  force_destroy = true

  lifecycle_rule {
    condition { age = 30 }
    action { type = "Delete" }
  }

  depends_on = [google_kms_crypto_key_iam_member.storage_agent]
}
