# Architecture

## Why this is folder-scoped

Organization policy inherits downward. A constraint set at the organization node applies to
every folder and project beneath it, including ones this repo did not create and has no business
touching. That property is why this stack deviates from Google's Enterprise Foundation Blueprint
in one specific way.

The identifiers a given deployment must never touch live in `config.env`, which is gitignored.
There is no default. A hardcoded one would protect whatever the repo's author happened to have
rather than whatever you have.

### Why stock EFB is dangerous in a shared organization

The EFB's `1-org` stage attaches organization policies, IAM bindings and an aggregated log sink
at the organization node. The moment you apply it, every folder and project in the org inherits
those constraints, including ones you did not build and do not want to change.

Applied to an org with anything running in it, stock EFB hands every existing project a deny-all
on external IPs, a block on service account key creation, mandatory uniform bucket-level access,
and a public-IP ban on Cloud SQL. Any of those can take an application down, and the failure
usually shows up hours later as an unrelated error rather than as a policy violation.

### What this repo does instead

```
organization
├── <everything else>          ← untouched. Inherits nothing from this repo.
└── gcp-study-playground/      ← created by stage 0. Everything attaches HERE or below.
    ├── <prefix>-seed          Terraform state, audit archive, asset feed
    ├── <prefix>-net           Shared VPC host
    ├── <prefix>-dev           Workloads
    └── <prefix>-sandbox       Disposable
```

Every org policy, every log sink, every firewall policy attaches at `folders/<playground>`.
GCP's policy model makes this safe: a folder-scoped policy applies to that subtree and nothing
else, so sibling folders are unaffected by the structure itself rather than by anyone
remembering to keep them out of it.

The organization is named exactly once, in `stacks/0-bootstrap`, as the parent of a new folder.
Creating a child does not alter what the organization applies to its existing children.

## The guard

Folder-scoping is the control. `scripts/guard.sh` is the backstop for when someone, quite
possibly me six months from now copying a snippet out of Google's blueprint, reaches for an
org-level resource without noticing.

It runs between `plan` and `apply` on every invocation, via `scripts/tf.sh`. There is no flag to
skip it.

**Layer 1: writes at the organization node.** Two kinds of resource reach the org node. Some
types have no folder-scoped form at all (`google_organization_iam_*`,
`google_logging_organization_sink`, `google_org_policy_custom_constraint`,
`google_access_context_manager_access_policy`). Others take a parent and could go either way
(`google_org_policy_policy`, `google_essential_contacts_contact`, `google_tags_tag_key`), so the
parent decides. Both kinds are collected with the organization they target and judged against
`ORG_WRITES_ALLOWED_FOR`. Unset, every org-node write is refused. Set to an org ID, writes to
that organization pass and writes to any other do not. A resource whose target organization
cannot be read is refused either way.

**Layer 2: protected identifiers.** Any planned change whose `before` *or* `after` state
mentions a protected ID from `config.env` is refused. Deliberately blunt: a false positive costs
a minute, a false negative costs an outage. An exported `PROTECTED_IDS` overrides the file, so CI
can set its own. Leaving it empty disables this layer alone, and layer 1 still blocks every
unauthorized org-node write.

**Layer 3: deletes.** Counted and reported, not refused. A destroy plan is supposed to be full
of deletes.

`google_folder` is exempt from layer 1. Creating the playground folder necessarily names the
organization as parent, and an early version of the filter blocked it, which would have made
stage 1 permanently unrunnable.

### The guard is tested

`make guard-test` runs `scripts/guard.sh` against 23 fixtures: twelve things it must refuse,
eleven it must permit. `scripts/preflight.sh` runs it before every bootstrap and fails the
bootstrap if it does not pass.

The fixtures have caught four real bugs so far. The guard blocked legitimate folder creation. It
permitted a *delete* inside a protected project, because it inspected only `after` state and a
delete's identity lives in `before`. It silently discarded a caller-supplied `PROTECTED_IDS`
because it sourced `config.env` afterwards. And a jq precedence mistake, where `|` binds looser
than `or`, made one condition reassociate into something that matched everything. None of those
were visible by reading the file.

## Running at the organization level

Folder-scoping is the correct default, but it cannot be the only mode. Real Enterprise
Foundation Blueprint deployments operate at the organization, three capabilities have no
folder-scoped form, and the exam assumes org-level thinking. The repo supports both, in
different organizations.

### What only the organization can do

| Capability | Why folders cannot |
|---|---|
| Custom org policy constraints | `google_org_policy_custom_constraint` is defined only at the organization. Without it you are limited to the constraints Google ships |
| Organization-wide log sinks | A folder sink sees its own subtree. Only an org sink captures folders that do not exist yet, including ones another operator creates |
| Default grant removal | On creation, an organization grants every domain user `projectCreator` and `billing.creator` at the org node. Revoking that is org IAM |

`stacks/1-org` implements all three.

### How it is gated

`ORG_WRITES_ALLOWED_FOR` names one organization by numeric ID. Org-node writes are permitted for
that organization and refused for every other, so pointing this repo at a different org re-locks
it without anyone having to remember to do so. A config that is merely stale fails closed.

A boolean would have been easier to write and worse to live with, because it is a switch you
turn on for the lab and forget to turn back off, and nothing tells you that it is still on.

Four checks, set in two files by two mechanisms, so no single careless edit opens them all:

1. `scripts/tf.sh` refuses the `1-org` stack before `init` if the value is unset or disagrees
   with `TF_VAR_org_id`. Nothing reaches an API.
2. `scripts/guard.sh` compares every org-node write in the plan against the allowed ID, and
   refuses any whose target organization it cannot determine.
3. `modules/org-policy-baseline` rejects an `organizations/` parent unless
   `allow_organization_parent` is set, as a Terraform variable validation.
4. `stacks/1-org` carries a `check` block asserting the two IDs match. The guard reads a plan
   file and could be sidestepped by running `terraform` directly. This cannot.

Eight of the 23 guard fixtures exist to prove one thing: unlocking the lab org does not unlock
any other.

### Getting an organization it is safe in

You need a second GCP organization, which means a second Cloud Identity account, which means a
domain not already tied to one. A different TLD of a domain you own works, since `example.dev`
and `example.com` are unrelated as far as Google is concerned. A subdomain is riskier, because
Google may entangle it with the parent's existing tenant.

[docs/org-setup.md](org-setup.md) is the step-by-step, including the mistake that wastes the
money: adding the new domain as a secondary domain of your existing Cloud Identity account
instead of creating a new account. That absorbs the domain into the tenant you already have and
produces no new organization at all.

### Two identities, one gcloud

Once there are two orgs there are two Google accounts and exactly one `gcloud`. Named
configurations keep them apart:

```bash
gcloud config configurations create lab
gcloud config configurations activate lab
```

`GCLOUD_CONFIGURATION` in `config.env` names the one a checkout should use, and
`scripts/auth.sh` activates it before anything else.

Configurations are per-configuration, but Application Default Credentials are global.
`gcloud auth application-default login` overwrites ADC for every configuration at once, and
Terraform reads ADC. So `gcloud` can report one organization while Terraform is authenticated
against another, with nothing on screen to suggest it. `auth.sh` resolves ADC's real identity
through the tokeninfo endpoint, since the credentials file does not record it, and refuses to
pass when the two disagree.

## Deviations from the stock EFB

| Stock EFB | Here | Why |
|---|---|---|
| Policies at the organization node | Folder node | See above |
| `2-environments` with dev/nonprod/prod folders | `2-projects` with net/dev/sandbox projects | A one-person lab does not have environments. It has "the thing I can delete" and "the thing holding my VPC" |
| Long-lived network stage | `3-network` in the destroyable tier | Cloud NAT is ~$32/month and dominates the bill |
| CI/CD pipeline via Cloud Build | `make` | The requirement was not to cd between stacks. A pipeline would be a different repo |
| Terraform service accounts with impersonation | Direct user ADC | Impersonation needs a service account, which needs a project, which needs the bootstrap to have run. Worth adding later as a study exercise, since it is how you would do this on a team |
| Org-level custom constraints | Available in `1-org` only | Blocked by the folder-only rule in the default mode. Implemented in `stacks/1-org`, which runs only in an explicitly unlocked organization |
| Assured Workloads for the NIST control package | Not used | Needs an entitlement personal billing accounts generally lack, and it deliberately makes folders hard to delete, which is the opposite of what a playground needs |

## Stage layout

The split is by lifetime and cost, not by function.

| Stage | Contents | Lifetime | Cost |
|---|---|---|---|
| `0-bootstrap` | Folder, seed project, state bucket | Permanent. `prevent_destroy` on folder and bucket | ~$0 |
| `1-foundation` | Org policy, audit sink, asset feed, contacts | Long-lived; leave it up | <$1/mo |
| `2-projects` | net, dev, sandbox projects | Long-lived. Projects are free | $0 |
| `3-network` | Shared VPC, NAT, DNS, KMS | Destroyable. `make lab-down` | ~$33/mo while up |
| `4-workload` | Hardened VM, encrypted bucket | Destroyable. `make lab-down` | ~$2/mo while up |
| `1-org` | Org policy, custom constraints, org-wide sink | Lab org only, opt-in | <$1/mo |

Stages hand off through `terraform_remote_state`, reading the stage below them out of GCS. That
is the EFB pattern and worth knowing for the exam, but it has a consequence: stages must be
applied in order and destroyed in reverse. `make up`, `make lab-up` and `make lab-down` handle
that ordering.

`stacks/1-foundation` and `stacks/2-projects` each carry a `check` block asserting that the
folder ID in `config.env` matches what the stage below actually created. A stale `config.env` is
otherwise a quiet way to point half the stack at the wrong folder.

## State

Stage 0 runs on local state, because it creates the bucket the others use.
`scripts/bootstrap.sh` applies it, reads the outputs, writes them into `config.env`, then writes
a backend block and runs `terraform init -migrate-state` so stage 0 ends up storing its state in
the bucket it just made.

Every other stage uses a partial backend, `backend "gcs" {}`, with bucket and prefix supplied by
`scripts/tf.sh` from `config.env`. Nothing about your state location is committed.

The state bucket has versioning on and keeps 10 generations. It also carries `prevent_destroy`,
so `make nuke` refuses it. That is intentional.

## Things GCP will not let you clean up

Worth knowing before you run this somewhere you care about.

**KMS key rings and keys cannot be deleted, ever.** `make lab-down` leaves them. Key versions
cost about $0.06/month each, so the residue is pennies, but it is permanent. They carry
`prevent_destroy` so Terraform does not repeatedly try and fail.

**Project IDs are burned permanently on delete.** A lab you rebuild weekly would exhaust a fixed
naming scheme, which is why `modules/project` appends a random suffix.

**A locked GCS retention policy cannot be shortened or removed.** `lock_retention` is off for
this reason.
