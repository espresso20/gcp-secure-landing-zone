# Organization policy baseline. Attaches at var.parent, which is a folder unless
# allow_organization_parent is set.
#
# Control IDs below are the technical controls each constraint contributes to, not controls it
# satisfies on its own. docs/control-mapping.md has the full version.

locals {
  # `true` means enforced. Defaults, not the maximum: anything that would make routine lab
  # work impossible is absent or opt-in (see enforce_cmek).
  boolean_defaults = {
    # Compute
    "compute.requireShieldedVm"            = true # SI-7   integrity: secure boot, vTPM, integrity monitoring
    "compute.requireOsLogin"               = true # AC-2, IA-2  SSH via IAM identity, not shared keys
    "compute.disableSerialPortAccess"      = true # AC-17  removes an out-of-band console path
    "compute.disableNestedVirtualization"  = true # CM-7   least functionality
    "compute.skipDefaultNetworkCreation"   = true # CM-7, SC-7  default VPC ships permissive firewall rules
    "compute.vmCanIpForward"               = true # SC-7   blocks VMs acting as unmanaged routers
    "compute.disableGuestAttributesAccess" = true # CM-7

    # compute.requireVpcFlowLogs is absent on purpose: it is a list constraint taking
    # ESSENTIAL / LIGHT / COMPREHENSIVE, not a boolean. The subnet log_config in
    # modules/secure-network is what produces the logs.

    # Identity
    "iam.disableServiceAccountKeyCreation"            = true # IA-5   long-lived keys are the top GCP credential-leak vector
    "iam.disableServiceAccountKeyUpload"              = true # IA-5
    "iam.automaticIamGrantsForDefaultServiceAccounts" = true # AC-6  default SAs get Editor otherwise

    # Storage
    "storage.uniformBucketLevelAccess" = true # AC-3   kills per-object ACLs, so IAM is the only path
    "storage.publicAccessPrevention"   = true # AC-3, AC-22  no accidental world-readable bucket

    # Data services
    "sql.restrictPublicIp"           = true # SC-7   Cloud SQL private IP only
    "sql.restrictAuthorizedNetworks" = true # SC-7   blocks 0.0.0.0/0 authorized networks
  }

  boolean_policies = merge(local.boolean_defaults, var.boolean_policy_overrides)

  # List constraints.
  list_policies = merge(
    {
      # No VM gets a public IP; IAP is the way in. AC-4, SC-7
      "compute.vmExternalIpAccess" = { deny_all = true }

      # SC-7
      "run.allowedIngress" = { allowed_values = ["is:internal-and-cloud-load-balancing"] }
    },
    # Data residency, and it also stops an accidental multi-region bucket. SC-7, SA-9
    length(var.allowed_locations) > 0 ? {
      "gcp.resourceLocations" = { allowed_values = var.allowed_locations }
    } : {},

    # Domain-restricted sharing. Without it any IAM binding can name an arbitrary gmail.com
    # account. Skipped rather than guessed when the customer ID is not set. AC-3, AC-20
    var.customer_id != null ? {
      "iam.allowedPolicyMemberDomains" = { allowed_values = ["is:${var.customer_id}"] }
    } : {},

    # CMEK. Opt-in; see variables.tf. SC-12, SC-13, SC-28
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
        # An empty values block passes Terraform and is then rejected by the API, with a
        # message that does not name the constraint responsible.
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
