# Stage 4 — workload. DESTROYABLE TIER.
#
# One hardened instance and one encrypted bucket. The point is not the workload; it is that
# every control from stages 1 and 3 is exercised by something real, so a `terraform apply` that
# succeeds proves the baseline is actually satisfiable.
#
# If any of these fail to create, the org policy baseline is doing its job. Read the error
# before relaxing anything.

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

# --- Workload identity ---------------------------------------------------------------------
#
# AC-6. The default Compute Engine service account holds Editor on the whole project. A
# dedicated account with nothing attached is the correct starting point; add roles when
# something actually fails.

resource "google_service_account" "vm" {
  project      = local.dev_project
  account_id   = "${var.prefix}-lab-vm"
  display_name = "Lab instance identity"
  description  = "Deliberately unprivileged. Grant roles as experiments require them."
}

# AU-12 — the instance can write its own logs and metrics, and nothing else.
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

# --- CMEK plumbing -----------------------------------------------------------------------------
#
# Service agents encrypt on your behalf, so they need decrypt rights on the key. Forgetting this
# produces a disk creation failure whose message does not mention KMS, which is a rite of
# passage and a reasonable exam question.

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

# --- The instance ----------------------------------------------------------------------------------

resource "google_compute_instance" "lab" {
  project      = local.dev_project
  name         = "${var.prefix}-lab-01"
  machine_type = var.machine_type
  zone         = var.default_zone
  labels       = local.labels

  boot_disk {
    initialize_params {
      # Shielded-VM-capable image. The org policy rejects anything else.
      image = "debian-cloud/debian-12"
      size  = 10
      type  = "pd-balanced"
    }
    # SC-28 — encryption at rest under a key you control and can destroy.
    kms_key_self_link = local.net.disk_key
  }

  network_interface {
    subnetwork = local.net.subnets["app"]
    # No access_config block. That absence is what denies the public IP; the org policy is the
    # backstop for when someone adds one back.
  }

  # SI-7 — secure boot, vTPM, integrity monitoring. Required by compute.requireShieldedVm.
  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  service_account {
    email = google_service_account.vm.email
    # Modern practice: full cloud-platform scope, constrained by IAM rather than by scopes.
    # Scopes are the legacy mechanism and predate fine-grained IAM.
    scopes = ["cloud-platform"]
  }

  metadata = {
    # AC-2, IA-2 — SSH keys come from IAM identity. Also enforced by org policy.
    enable-oslogin = "TRUE"
    # AC-17 — no metadata-server-based serial console backdoor.
    serial-port-enable = "FALSE"
  }

  # A stopped instance costs only its disk. Useful when you want the lab to survive overnight
  # without the compute charge.
  desired_status = "RUNNING"

  depends_on = [google_kms_crypto_key_iam_member.compute_agent]
}

# --- Access -----------------------------------------------------------------------------------------
#
# AC-17. There is no public IP and no firewall rule permitting the internet. The only path is
# IAP TCP forwarding, which the hierarchical firewall policy in stage 3 permits from
# 35.235.240.0/20, and which requires an IAM role to use.
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

# --- Encrypted storage ----------------------------------------------------------------------------------

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

  # Lab data. Nothing here should be precious.
  force_destroy = true

  lifecycle_rule {
    condition { age = 30 }
    action { type = "Delete" }
  }

  depends_on = [google_kms_crypto_key_iam_member.storage_agent]
}
