# NIST 800-53 Rev. 5 — Moderate baseline mapping

## What this document claims, and what it does not

This stack does **not** make a GCP folder "NIST 800-53 compliant". No Terraform can.

The Moderate baseline is roughly 320 controls across 20 families. The large majority are
organizational and procedural: who you background-check before granting access (PS-3), how you
train them (AT-2), what your contingency plan says (CP-2), how you physically control the room
the servers are in (PE-3). Configuration cannot satisfy those, and any tool claiming otherwise
is selling something.

What this stack does is implement the **technically enforceable subset** — the controls whose
satisfaction is genuinely a matter of how the cloud environment is configured — and leave an
auditable record of which ones those are.

Three categories, and every control in the baseline falls into exactly one:

| Category | Meaning | Count here |
|---|---|---|
| **Implemented** | This Terraform configures something that materially contributes | 41 controls across 7 families |
| **Inherited** | Google satisfies it under their own FedRAMP authorization; you consume it | Most of PE, MA, MP, and parts of SC |
| **Not applicable / procedural** | Requires a human, a policy document, or an organization | The rest, including all of AT, PS, PL, CP |

"Implemented" is still not "satisfied". A control is satisfied when the configuration exists,
someone monitors it, someone reviews the monitoring, and there is evidence of all three. This
stack gives you the first, makes the second possible, and does nothing at all about the third.

---

## Implemented

### AC — Access Control

| Control | What it wants | Where this stack does it |
|---|---|---|
| AC-2 | Account management | `compute.requireOsLogin` — SSH identity is an IAM identity, so account lifecycle is IAM lifecycle. `modules/org-policy-baseline` |
| AC-3 | Access enforcement | `storage.uniformBucketLevelAccess` removes per-object ACLs so IAM is the only path; `storage.publicAccessPrevention` |
| AC-4 | Information flow enforcement | `compute.vmExternalIpAccess` deny-all; hierarchical firewall default-deny in `modules/secure-network` |
| AC-6 | Least privilege | `iam.automaticIamGrantsForDefaultServiceAccounts` (blocks the automatic Editor grant); dedicated unprivileged VM service account in `stacks/4-workload`; subnet-scoped rather than project-scoped `compute.networkUser` |
| AC-17 | Remote access | No public IPs. IAP TCP forwarding is the only ingress path, permitted from 35.235.240.0/20 and gated by `roles/iap.tunnelResourceAccessor`. `compute.disableSerialPortAccess` closes the out-of-band route |
| AC-20 | Use of external systems | `iam.allowedPolicyMemberDomains` — IAM bindings cannot name identities outside your Cloud Identity tenant. **Requires `TF_VAR_customer_id`; skipped silently if unset** |
| AC-22 | Publicly accessible content | `storage.publicAccessPrevention` enforced |

### AU — Audit and Accountability

| Control | What it wants | Where |
|---|---|---|
| AU-2 | Event logging | Folder-level aggregated sink with `include_children`, `modules/audit-logging` |
| AU-3 | Content of audit records | Cloud Audit Logs format; `INCLUDE_ALL_METADATA` on VPC flow logs |
| AU-4 | Storage capacity | GCS archive with lifecycle tiering; Cloud Logging bucket with explicit retention |
| AU-6 | Review and analysis | Cloud Logging bucket is queryable. **The review itself is procedural and not implemented** |
| AU-9 | Protection of audit information | Bucket versioning; uniform bucket-level access; optional retention lock (`lock_retention`, off by default — see below) |
| AU-11 | Audit record retention | `audit_retention_days`, default 365 |
| AU-12 | Audit record generation | `google_project_iam_audit_config` enables DATA_READ/DATA_WRITE on all services in every project — these are **off by default in GCP** and are the ones that tell you who read the data. Plus VPC flow logs and Cloud NAT logging |

### CM — Configuration Management

| Control | What it wants | Where |
|---|---|---|
| CM-2 | Baseline configuration | The repo itself. Every resource is declarative and version-controlled |
| CM-3 | Configuration change control | `google_cloud_asset_folder_feed` emits every resource and IAM change to Pub/Sub |
| CM-6 | Configuration settings | The org policy baseline is the setting enforcement mechanism |
| CM-7 | Least functionality | `auto_create_network = false`; `compute.skipDefaultNetworkCreation`; `compute.disableNestedVirtualization`; `compute.disableGuestAttributesAccess`; explicit per-project API allowlists rather than enabling everything |

### IA — Identification and Authentication

| Control | What it wants | Where |
|---|---|---|
| IA-2 | Identification and authentication | OS Login binds SSH to Google identity |
| IA-5 | Authenticator management | `iam.disableServiceAccountKeyCreation` and `...KeyUpload`. Long-lived service account keys are the single most common GCP credential-leak vector; this removes the ability to make one |

### SC — System and Communications Protection

| Control | What it wants | Where |
|---|---|---|
| SC-7 | Boundary protection | Custom-mode VPC; hierarchical firewall policy with default-deny at the folder, which a project owner cannot override; `sql.restrictPublicIp`; `sql.restrictAuthorizedNetworks`; `run.allowedIngress`; Private Google Access with restricted VIPs |
| SC-8 | Transmission confidentiality | Google-managed TLS in transit, plus private DNS routing `*.googleapis.com` to `restricted.googleapis.com` so API traffic never traverses the internet |
| SC-12 | Cryptographic key management | Cloud KMS key ring with 90-day automatic rotation, `stacks/3-network` |
| SC-13 | Cryptographic protection | CMEK on boot disks and buckets |
| SC-28 | Protection of information at rest | `kms_key_self_link` on disks; `default_kms_key_name` on buckets. Optional `gcp.restrictNonCmekServices` makes it mandatory |

### SI — System and Information Integrity

| Control | What it wants | Where |
|---|---|---|
| SI-4 | System monitoring | Asset feed; flow logs; NAT logging; audit sink |
| SI-7 | Software/firmware/information integrity | `compute.requireShieldedVm` — secure boot, vTPM, integrity monitoring |

### IR — Incident Response

| Control | What it wants | Where |
|---|---|---|
| IR-6 | Incident reporting | Essential Contacts at the folder for SECURITY, TECHNICAL, SUSPENSION. **Requires `security_contact_email`** |

---

## Inherited from Google

You do not implement these; Google does, and their FedRAMP Moderate authorization covers them.
In a real ATO package these appear as inherited controls with Google's authorization as the
evidence. Listed because "we didn't do it" and "someone else did it" are very different answers
to an auditor.

- **PE** (Physical and Environmental Protection) — entirely. You have no physical access to
  Google's facilities and no ability to control it.
- **MA** (Maintenance) — hardware maintenance of the underlying infrastructure.
- **MP** (Media Protection) — media sanitization and disposal for physical disks.
- **SC-5** (Denial of service protection) — Google's edge.
- **SA-22** (Unsupported system components) — for managed services.

---

## Not implemented, and why

This is the section that makes the document useful. A mapping with no gaps section is a
marketing document.

### Procedural — cannot be Terraformed

Entire families: **AT** (Awareness and Training), **PS** (Personnel Security), **PL**
(Planning), **CP** (Contingency Planning), **PM** (Program Management), **SR** (Supply Chain
Risk Management). Plus AU-6's actual review activity, CA-2 (assessments), CA-7 (continuous
monitoring as a *program*), IR-2 through IR-5 (the response capability itself).

A one-person study lab has no meaningful version of most of these.

### Deliberately deferred — cost

| Control | What would satisfy it | Why not here |
|---|---|---|
| CA-7, RA-5, SI-3 | Security Command Center Premium/Enterprise, which ships built-in NIST 800-53 posture templates and continuous vulnerability scanning | SCC Premium is priced for enterprises. Adding it would multiply this lab's cost by an order of magnitude, against a stated ceiling of $20/month |
| SC-7(21) | VPC Service Controls perimeter around the folder's projects | Significant operational complexity, and a misconfigured perimeter locks you out of your own project. Worth building deliberately as a study exercise; wrong as a default |
| AU-9(3) | Locked GCS retention policy on the audit archive | `lock_retention` exists and is **off**. A locked bucket cannot be deleted until every object ages out — turning it on strands `make lab-down` for a year. Correct for production, wrong for a playground |

### Deliberately deferred — blast radius

| Control | What would satisfy it | Why not here |
|---|---|---|
| CM-6, AC-3 | `google_org_policy_custom_constraint` — custom constraints for cases the built-in ones miss | Custom constraints can only be defined at the **organization** node. This repo is folder-scoped so that a sibling folder cannot inherit anything it sets, and `scripts/guard.sh` blocks the resource type outright. This is a real capability lost to that rule, and it is the main one |
| AU-6, SI-4 | Organization-scoped SCC findings and asset queries | Same reason. `stacks/1-foundation` uses org-level *data sources* only, which read and cannot mutate |

### Known weaknesses of the implementation

- **Data access logs have a cost profile that scales with use.** At lab volume this is
  negligible. Enabling `DATA_READ` on `allServices` in a busy real-world project is not a
  decision to copy from here without measuring.
- **The audit archive lives in the seed project**, which is inside the same folder it audits. A
  sufficiently privileged compromise of the folder could tamper with both. Proper separation
  puts the logging project under a different administrative boundary. Out of scope at this
  budget, but it is a genuine finding and an auditor would raise it.
- **No separation of duties.** One human has every role. AC-5 is not implemented and cannot be
  in a single-operator lab.
- **`gcp.resourceLocations` is set to `in:us-locations`,** which is a data-residency choice, not
  a security control. It appears here mostly because it also prevents accidental multi-region
  resources that would blow the budget.

---

## Using this for the exam

The mapping is more useful as a study artifact than as a compliance artifact. The pattern worth
internalizing: given a control, name the GCP mechanism. Given a GCP mechanism, name what it
actually prevents.

The exam rarely asks "is this compliant". It asks "which of these four options enforces X across
every project in a folder without letting a project owner override it" — and the answer is a
hierarchical firewall policy or an org policy, because those are the two mechanisms with that
property. See [exam-notes.md](exam-notes.md).
