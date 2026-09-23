# Folder-scoped organization policy baseline.
#
# Every constraint here attaches at var.parent, which is validated to be a folder or project.
# Nothing in this module can write at the organization node.
#
# The NIST 800-53 Rev. 5 control references in the comments are the *technical* controls each
# constraint contributes to. None of them fully satisfies a control on its own — a control is
# satisfied by a combination of configuration, monitoring and procedure. docs/control-mapping.md
# is the honest version of this; the comments are here so the mapping survives next to the code.

locals {
  # Boolean constraints. `true` means the constraint is enforced.
  #
  # These are the defensible defaults, not the maximum. Anything that would make routine lab
  # work impossible is either absent or opt-in (see enforce_cmek).
  boolean_defaults = {
    # --- Compute / workload hardening ----------------------------------------------------
    "compute.requireShieldedVm"            = true # SI-7   integrity: secure boot, vTPM, integrity monitoring
    "compute.requireOsLogin"               = true # AC-2, IA-2  SSH via IAM identity, not shared keys
    "compute.disableSerialPortAccess"      = true # AC-17  removes an out-of-band console path
    "compute.disableNestedVirtualization"  = true # CM-7   least functionality
    "compute.skipDefaultNetworkCreation"   = true # CM-7, SC-7  default VPC ships permissive firewall rules
    "compute.vmCanIpForward"               = true # SC-7   blocks VMs acting as unmanaged routers
    "compute.disableGuestAttributesAccess" = true # CM-7

    # Not listed: compute.requireVpcFlowLogs. It is a LIST constraint taking
    # ESSENTIAL / LIGHT / COMPREHENSIVE, not a boolean, and the subnet log_config in
    # modules/secure-network is what actually produces the logs. AU-12 is covered there.

    # --- Identity -------------------------------------------------------------------------
    "iam.disableServiceAccountKeyCreation"            = true # IA-5   long-lived keys are the top GCP credential-leak vector
    "iam.disableServiceAccountKeyUpload"              = true # IA-5
    "iam.automaticIamGrantsForDefaultServiceAccounts" = true # AC-6  default SAs get Editor otherwise

    # --- Storage --------------------------------------------------------------------------
    "storage.uniformBucketLevelAccess" = true # AC-3   kills per-object ACLs, so IAM is the only path
    "storage.publicAccessPrevention"   = true # AC-3, AC-22  no accidental world-readable bucket

    # --- Data services --------------------------------------------------------------------
    "sql.restrictPublicIp"           = true # SC-7   Cloud SQL private IP only
    "sql.restrictAuthorizedNetworks" = true # SC-7   blocks 0.0.0.0/0 authorized networks
  }

  boolean_policies = merge(local.boolean_defaults, var.boolean_policy_overrides)

  # List constraints.
  list_policies = merge(
    {
      # AC-4, SC-7 — no VM gets a public IP. IAP TCP forwarding is the way in; the network
      # module opens 35.235.240.0/20 for exactly that.
      "compute.vmExternalIpAccess" = { deny_all = true }

      # SC-7 — Cloud Run reachable only through internal traffic or a load balancer.
      "run.allowedIngress" = { allowed_values = ["is:internal-and-cloud-load-balancing"] }
    },
    # SC-7, SA-9 — data residency. Also the cheapest way to stop an accidental multi-region
    # bucket in a lab that is supposed to cost under $20/month.
    length(var.allowed_locations) > 0 ? {
      "gcp.resourceLocations" = { allowed_values = var.allowed_locations }
    } : {},

    # AC-3, AC-20 — domain-restricted sharing. Without this, any IAM binding can name an
    # arbitrary gmail.com account. Needs the Cloud Identity customer ID, so it is skipped
    # rather than guessed when that is not configured.
    var.customer_id != null ? {
      "iam.allowedPolicyMemberDomains" = { allowed_values = ["is:${var.customer_id}"] }
    } : {},

    # SC-12, SC-13, SC-28 — customer-managed encryption keys. Opt-in: see variables.tf.
    var.enforce_cmek ? {
      "gcp.restrictNonCmekServices" = {
        denied_values = [
          "bigquery.googleapis.com",
          "storage.googleapis.com",
          "compute.googleapis.com",
        ]
      }
    } : {}
  )
}

resource "google_org_policy_policy" "boolean" {
  for_each = local.boolean_policies

  name   = "${var.parent}/policies/${each.key}"
  parent = var.parent

  spec {
    rules {
      enforce = each.value ? "TRUE" : "FALSE"
    }
  }
}

resource "google_org_policy_policy" "list" {
  for_each = local.list_policies

  name   = "${var.parent}/policies/${each.key}"
  parent = var.parent

  spec {
    rules {
      allow_all = try(each.value.allow_all, false) ? "TRUE" : null
      deny_all  = try(each.value.deny_all, false) ? "TRUE" : null

      dynamic "values" {
        # Only emit a values block when there is something to put in it. An empty values block
        # is accepted by Terraform and then rejected by the API with a message that does not
        # mention which constraint caused it.
        for_each = (
          try(each.value.allowed_values, null) != null ||
          try(each.value.denied_values, null) != null
        ) ? [1] : []

        content {
          allowed_values = try(each.value.allowed_values, null)
          denied_values  = try(each.value.denied_values, null)
        }
      }
    }
  }
}
