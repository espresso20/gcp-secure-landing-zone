# Exam notes — ACE → PCA

Tied to the resources in this repo, because the thing that makes a fact stick is having broken
it once. Where a note says "go look", there is a specific command to run against your own stack.

---

## Resource hierarchy

Organization → Folder → Project → Resource. Both exams lean on this hard.

**The rule that generates most of the questions:** IAM policy and Organization Policy both
inherit **downward** and are **additive** for IAM, **restrictive** for org policy.

- IAM: a role granted at the folder is held on every project beneath it. You cannot subtract a
  role lower down. There is no "deny" in basic IAM — Deny Policies exist but are a separate,
  newer mechanism.
- Org policy: a constraint set at the folder applies below it. A project *can* override with its
  own policy **only if** the parent policy does not set `inheritFromParent` appropriately, and
  boolean constraints can be reset at a lower node. This is why the exam distinguishes org
  policy from hierarchical firewall policies — the latter genuinely cannot be overridden below.

> **Go look:** `gcloud resource-manager org-policies list --folder=$TF_VAR_folder_id`
> then the same for one of your projects, and compare.

**Why this repo is folder-scoped** is itself the lesson: see [architecture.md](architecture.md).
If someone asks "how do I apply a policy to some projects but not others", the answer is
"restructure the folder hierarchy", not "apply it everywhere and make exceptions".

---

## Projects

- Project **ID** is globally unique, immutable, and **permanently burned when you delete the
  project**. Project **number** is auto-assigned and is what service agent emails are built from.
  Project **name** is a display label and means nothing.
- Deleting a project is a 30-day soft delete. It can be restored within that window.
- `modules/project/main.tf` appends a random suffix precisely because IDs are burned.

**Service agents vs service accounts** — a reliable exam discriminator:

| Thing | Looks like | What it is |
|---|---|---|
| Default compute SA | `<number>-compute@developer.gserviceaccount.com` | What VMs run as by default. Has Editor. This is the one you should stop using |
| Google APIs service agent | `<number>@cloudservices.gserviceaccount.com` | What Google services use to act on your behalf. **Needs `compute.networkUser` for Shared VPC** |
| Per-service agents | `service-<number>@compute-system.iam.gserviceaccount.com`, `...@gs-project-accounts...` | Per-product. **These are what need `cryptoKeyEncrypterDecrypter` for CMEK** |

Forgetting the third row produces a disk-creation error that does not mention KMS. See the
comments in `stacks/4-workload/main.tf`.

---

## Networking

**Auto-mode vs custom-mode VPC.** Auto-mode creates a subnet in every region with predetermined
`10.128.0.0/9` ranges. Custom-mode creates nothing until you say so. The exam answer for
anything production-shaped is custom-mode — you cannot control CIDR otherwise, and auto-mode
ranges collide when you later peer or connect on-premises.

**The default network** ships with `default-allow-ssh` and `default-allow-rdp` open to
`0.0.0.0/0`. This is why `auto_create_network = false` and
`compute.skipDefaultNetworkCreation` both appear in this repo. Belt and braces on purpose.

**Shared VPC.** One host project owns the network; service projects place resources in it.

- Host project needs `compute.googleapis.com` and to be enabled as a host.
- The principal that *creates* the instance needs `roles/compute.networkUser` **on the subnet**,
  not on the project, if you want least privilege.
- `<number>@cloudservices.gserviceaccount.com` for each service project needs it too.
- Granting `networkUser` at the host *project* level gives access to **every** subnet. That is
  the wrong answer on the exam and in life.

**Firewall evaluation order** — near-guaranteed question:

1. Hierarchical firewall policies (org, then folder) — evaluated first, cannot be overridden below
2. VPC firewall rules (by priority, 0–65535, lower wins)
3. Implied rules: allow all egress, deny all ingress

`modules/secure-network` puts an explicit deny-all at priority 65000 in the folder policy, with
IAP and health checks permitted above it.

**Fixed ranges worth memorising:**

| Range | What |
|---|---|
| `35.235.240.0/20` | IAP TCP forwarding. The only ingress this stack permits |
| `35.191.0.0/16`, `130.211.0.0/22` | Google health checks and LB data plane |
| `199.36.153.4/30` | `restricted.googleapis.com` — VPC-SC-compatible Private Google Access |
| `199.36.153.8/30` | `private.googleapis.com` — Private Google Access without VPC-SC |

**Private Google Access** lets an instance with no external IP reach Google APIs. It is a
**subnet** setting (`private_ip_google_access`). Without it, a private VM cannot pull a container
image. The DNS half — routing `*.googleapis.com` to a restricted VIP — is separate and is in
`modules/secure-network`.

**Cloud NAT** provides *outbound* internet for instances with no external IP. It does not permit
inbound. It is regional, attaches to a Cloud Router, and is the most expensive thing in this repo.

---

## IAM

**Basic vs predefined vs custom.** Basic roles (Owner/Editor/Viewer) predate IAM and are far too
broad — Editor can delete almost anything. Any exam question offering a basic role as an answer
is usually offering the wrong answer.

**Service account impersonation over keys.** `iam.disableServiceAccountKeyCreation` in this repo
removes the ability to create a downloadable key at all. The replacements:

- `--impersonate-service-account` for a human doing something as an SA
- Workload Identity Federation for CI outside GCP
- Attached service accounts for anything running inside GCP

**`roles/iam.serviceAccountUser` vs `roles/iam.serviceAccountTokenCreator`** — a classic:
`serviceAccountUser` lets you *attach* an SA to a resource (deploy a VM that runs as it);
`serviceAccountTokenCreator` lets you *mint tokens* as it (impersonate it directly).

**OS Login vs metadata SSH keys.** OS Login ties Linux accounts to IAM identities, supports
2FA, and gives centralised revocation. Metadata keys are per-project or per-instance and survive
IAM removal. `compute.requireOsLogin` forces the former.

---

## Logging and monitoring

**Four audit log types:**

| Type | Default | Content |
|---|---|---|
| Admin Activity | **Always on, cannot be disabled, free** | Config changes |
| System Event | Always on, free | Google-initiated actions |
| Data Access | **Off by default**, billable | Who read or wrote data |
| Policy Denied | On, billable | Denied by VPC-SC or org policy |

Data Access being off by default is the most exam-tested fact in this section. This repo turns
it on in `modules/project` via `google_project_iam_audit_config`.

**Sinks.** An aggregated sink at a folder with `include_children = true` captures every project
below it. Destinations: Cloud Logging bucket, GCS, BigQuery, Pub/Sub. Each sink gets a **writer
identity** that must be granted permission on the destination — creating the sink and forgetting
that grant is a standard trap.

> **Go look:** `make output STACK=1-foundation` shows the writer identity.

**Log retention.** `_Required` bucket: 400 days, not configurable, free. `_Default`: 30 days,
configurable, billable beyond 30.

---

## Encryption

- **Google-managed** — default, invisible, free.
- **CMEK** — your key in Cloud KMS, you control rotation and destruction. What this repo uses.
- **CSEK** — you supply raw key material with every call; Google never stores it. Rare, and
  being deprecated for most services.

Key rotation is automatic with `rotation_period`; **rotation does not re-encrypt existing data**,
it only applies to new encryptions. Old key versions must stay enabled or existing data becomes
unreadable. Destroying a key version is a 24-hour scheduled destruction.

Key rings and keys **cannot be deleted**. Plan naming accordingly.

---

## Cost

Relevant to PCA specifically, which asks a lot of "cheapest option that meets the requirement".

- **Committed use discounts** — 1 or 3 year, per-project or shared, for predictable baseline.
- **Sustained use discounts** — automatic, no commitment, on sustained monthly usage.
- **Spot/Preemptible VMs** — up to 90% off, can be reclaimed. Fine for batch, wrong for stateful.
- **Budgets alert; they do not cap.** To actually stop spend you wire the budget's Pub/Sub topic
  to a function that disables billing — and disabling billing destroys resources. The exam wants
  you to know the alert is not a cap.

> **Go look:** `make cost` breaks down what this stack costs and where.

---

## Quick self-test against your own stack

Once `make up && make lab-up` has run:

1. Try to create a VM with an external IP in the dev project. It should fail. Which constraint?
2. Try `gcloud compute ssh` without `--tunnel-through-iap`. Why does it hang rather than refuse?
3. Create a service account key. Which error, and at which node is the policy set?
4. Make a bucket public with `gsutil iam ch allUsers:objectViewer`. Two separate controls block
   this — name both.
5. Query the audit log for your own `setIamPolicy` calls. Which log type were they in?
6. Delete the hierarchical firewall deny-all rule from the console as project owner of `dev`.
   Why can't you?

Answers are all in this repo. That is the point of it.
