# Architecture

## The constraint that shaped everything

Organization policy inherits downward. A constraint set at the organization node applies to
every folder and project beneath it, including ones this repo did not create and has no business
touching. That single property is why this stack deviates from Google's Enterprise Foundation
Blueprint in one specific and important way.

The identifiers a given deployment must never touch live in `config.env`, which is gitignored.
There is no default: a hardcoded one would protect whatever the repo's author happened to have
rather than whatever you have.

### Why stock EFB is dangerous in a shared organization

The EFB's `1-org` stage attaches organization policies, IAM bindings and an aggregated log sink
at the **organization node**. Organization policy inherits downward. The moment you apply it,
every folder and project in the org inherits the constraints — including ones you did not build
and do not want to change.

Applied to an org with anything real in it, stock EFB hands every existing project a deny-all on
external IPs, a block on service account key creation, mandatory uniform bucket-level access,
and a public-IP ban on Cloud SQL. Any of those can take a running application down, and the
failure presents as an unrelated error hours later rather than as a policy violation.

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
GCP's policy model makes this genuinely safe: a folder-scoped policy applies to that subtree and
nothing else. Sibling folders are unaffected by construction, not by convention.

The organization is named exactly once, in `stacks/0-bootstrap`, as the parent of a new folder.
Creating a child does not alter what the organization applies to its existing children.

## The guard

Folder-scoping is the control. `scripts/guard.sh` is the backstop for when someone — most
likely a future version of me, copying a snippet from Google's blueprint — reaches for an
org-level resource without noticing.

It runs between `plan` and `apply` on every single invocation, via `scripts/tf.sh`. There is no
flag to skip it. Three layers:

1. **Resource type denylist.** Resources with no folder-scoped form: `google_organization_iam_*`,
   `google_logging_organization_sink`, `google_org_policy_custom_constraint`,
   `google_access_context_manager_access_policy`, and others. Unconditional refusal.

2. **Parent inspection.** Resources that could go either way — `google_org_policy_policy`,
   `google_essential_contacts_contact`, `google_tags_tag_key` — are checked for a parent
   starting with `organizations/`.

3. **Protected identifier scan.** Any planned change whose `before` *or* `after` state mentions
   a protected ID from `config.env` is refused. Deliberately blunt: a false positive costs a
   minute, a false negative costs an outage. An exported `PROTECTED_IDS` overrides the file, so
   CI can set its own. Leaving it empty disables this layer only — layers 1 and 1b still block
   every org-node write.

`google_folder` is explicitly exempt from layer 2. Creating the playground folder necessarily
names the organization as parent, and an early version of the filter blocked it — which would
have made stage 1 permanently unrunnable.

### The guard is tested

`make guard-test` runs `scripts/guard.sh` against 15 fixtures: eight things it must refuse,
seven it must permit. `scripts/preflight.sh` runs it before every bootstrap and fails the
bootstrap if it does not pass.

This is not ceremony. The fixtures have caught three real bugs so far: the guard blocked
legitimate folder creation; it permitted a *delete* inside a protected project because it
inspected only `after` state, and a delete's identity lives in `before`; and it silently
discarded a caller-supplied `PROTECTED_IDS` because it sourced `config.env` afterwards. All
three were invisible without the tests. A guard nobody tests is a guard nobody should rely on.

## Deviations from the stock EFB

| Stock EFB | Here | Why |
|---|---|---|
| Policies at the organization node | Folder node | The whole point. See above |
| `2-environments` with dev/nonprod/prod folders | `2-projects` with net/dev/sandbox projects | A one-person lab does not have environments. It has "the thing I can delete" and "the thing holding my VPC" |
| Long-lived network stage | `3-network` in the destroyable tier | Cloud NAT is ~$32/month and dominates the bill |
| CI/CD pipeline via Cloud Build | `make` | You asked not to cd between stacks. A pipeline would be a different repo |
| Terraform service accounts with impersonation | Direct user ADC | Impersonation needs a service account, which needs a project, which needs the bootstrap to have run. Worth adding later as a study exercise; it is genuinely how you would do this on a team |
| Org-level custom constraints | Not available | Blocked by the folder-only rule. The one real capability lost — see control-mapping.md |
| Assured Workloads for the NIST control package | Not used | Needs an entitlement personal billing accounts generally lack, and it deliberately makes folders hard to delete — the opposite of what a playground needs |

## Stage layout and why it splits where it does

The split is by **lifetime and cost**, not by function.

| Stage | Contents | Lifetime | Cost |
|---|---|---|---|
| `0-bootstrap` | Folder, seed project, state bucket | Permanent. `prevent_destroy` on folder and bucket | ~$0 |
| `1-foundation` | Org policy, audit sink, asset feed, contacts | Long-lived; leave it up | <$1/mo |
| `2-projects` | net, dev, sandbox projects | Long-lived. Projects are free | $0 |
| `3-network` | Shared VPC, NAT, DNS, KMS | **Destroyable.** `make lab-down` | ~$33/mo while up |
| `4-workload` | Hardened VM, encrypted bucket | **Destroyable.** `make lab-down` | ~$2/mo while up |

Stages hand off through `terraform_remote_state`, reading the stage below them out of GCS. That
is the EFB pattern and it is worth knowing for the exam, but it has a consequence: stages must
be applied in order and destroyed in reverse. `make up`, `make lab-up` and `make lab-down` do
that ordering for you.

`stacks/1-foundation` and `stacks/2-projects` each carry a `check` block asserting that the
folder ID in `config.env` matches what the stage below actually created. A stale `config.env` is
otherwise a silent way to point half the stack at the wrong folder.

## State

Stage 0 runs on local state, because it creates the bucket the others use. `scripts/bootstrap.sh`
applies it, reads the outputs, writes them into `config.env`, then writes a backend block and
runs `terraform init -migrate-state` so stage 0 ends up storing its state in the bucket it just
made.

Every other stage uses a partial backend — `backend "gcs" {}` with bucket and prefix supplied by
`scripts/tf.sh` from `config.env`. Nothing about your state location is committed.

The state bucket has versioning on and keeps 10 generations. It also has `prevent_destroy`, so
`make nuke` will refuse it, which is intentional.

## Things GCP will not let you clean up

Worth knowing before you run this somewhere you care about:

- **KMS key rings and keys cannot be deleted. Ever.** `make lab-down` leaves them. Key versions
  cost about $0.06/month each, so the residue is pennies, but it is permanent. They carry
  `prevent_destroy` so Terraform does not repeatedly try and fail.
- **Project IDs are burned permanently on delete.** A lab you rebuild weekly would exhaust a
  fixed naming scheme, which is why `modules/project` appends a random suffix.
- **A locked GCS retention policy cannot be shortened or removed.** `lock_retention` is off for
  this reason.
