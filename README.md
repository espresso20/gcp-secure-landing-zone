# gcp-secure-landing-zone

A folder-scoped GCP landing zone in Terraform — built to study for the ACE → PCA path, and to
have somewhere safe to break things.

Implements the technically enforceable subset of the **NIST 800-53 Rev. 5 Moderate** baseline
and the GCP well-architected / Enterprise Foundation Blueprint patterns — with one deliberate
deviation from stock EFB, described below, that exists to keep the rest of the organization out
of the blast radius.

```
make help
```

---

## The one thing to read before running anything

Stock EFB attaches org policies and log sinks at the **organization node**, where every folder
in the org inherits them — including folders you did not intend to touch. **This repo
attaches everything at the folder instead.**

`scripts/guard.sh` runs between every `plan` and `apply` and refuses any plan that writes above
the playground folder or mentions a protected identifier. It is not skippable and it is tested —
`make guard-test` runs it against 15 fixtures.

Full reasoning: [docs/architecture.md](docs/architecture.md).

**If you want the org-level build instead** — real EFB, custom constraints, org-wide sinks —
do it in a *separate* organization with nothing in it, and unlock that one org by ID:

```bash
ORG_WRITES_ALLOWED_FOR="123456789012"   # that org and no other
make org-up
```

It is not a boolean. Point the repo at a different org and it re-locks itself.
[docs/org-setup.md](docs/org-setup.md) is the checklist for standing up an org it is safe in.

---

## Quickstart

```bash
make init-config          # creates config.env
make auth                 # gcloud + ADC sign-in, plus org/billing access checks
make ids                  # prints your org ID, billing account, customer ID
$EDITOR config.env        # paste those in, pick a prefix
make preflight            # verifies everything before anything is created
make bootstrap            # stage 0: folder, seed project, state bucket
make up                   # foundation: org policy, audit, projects
make lab-up               # network + workload  ← this is the part that costs money
```

When you stop studying:

```bash
make lab-down             # back to under $1/month
```

---

## What gets built

```
organization
├── <everything else>          ← untouched, inherits nothing from this repo
└── gcp-study-playground/      ← everything attaches here or below
    ├── <prefix>-seed          state bucket, audit archive, asset feed
    ├── <prefix>-net           Shared VPC host, Cloud NAT, KMS
    ├── <prefix>-dev           hardened VM (IAP-only, CMEK, Shielded), encrypted bucket
    └── <prefix>-sandbox       disposable
```

| Stage | Contents | Lifetime | Cost while up |
|---|---|---|---|
| `0-bootstrap` | Folder, seed project, state bucket | Permanent | ~$0 |
| `1-foundation` | Org policy baseline, audit sink, asset feed, Essential Contacts | Leave it up | <$1/mo |
| `2-projects` | net / dev / sandbox | Leave it up | $0 |
| `3-network` | Shared VPC, subnets, NAT, DNS, hierarchical firewall, KMS | Destroyable | ~$33/mo |
| `4-workload` | Shielded VM behind IAP, CMEK bucket | Destroyable | ~$2/mo |
| `1-org` | Org policy, custom constraints, org-wide sink | **Lab org only, opt-in** | <$1/mo |

`make cost` breaks this down. Cloud NAT is the single largest item; set `enable_nat = false` in
`stacks/3-network` to drop it, at the cost of no outbound internet from private instances.

---

## Make targets

Everything runs from the repo root. No `cd`.

| | |
|---|---|
| `make up` / `make down` | foundation up / everything below stage 0 down |
| `make lab-up` / `make lab-down` | the expensive half, up / down |
| `make plan STACK=3-network` | per stack; also `make plan-3-network` |
| `make apply STACK=…`, `make destroy STACK=…`, `make output STACK=…` | same shape |
| `make status` | what currently exists across all stages |
| `make cost` | standing cost breakdown |
| `make validate` / `make fmt` / `make lint` | quality |
| `make org-check` | show which org, if any, is unlocked for org-node writes |
| `make org-up` / `make org-down` | apply / destroy `1-org` — lab org only |
| `make guard-test` | prove the blast-radius guard still works (23 fixtures) |
| `make nuke` | everything, including stage 0. Asks you to type a word |

`plan` and `apply` both re-plan and run the guard every time. Applying a stale plan file is how
you apply something you did not read.

---

## Layout

```
Makefile                      orchestration; nothing else needs a cd
config.env.example            copy to config.env — org/billing IDs, prefix, protected IDs
scripts/
  auth.sh                     gcloud + ADC sign-in, org and billing access checks
  preflight.sh                everything that must be true before the first apply
  bootstrap.sh                 stage 0 apply → write config.env → migrate state
  tf.sh                       terraform wrapper: backend config, guard, plugin cache
  guard.sh                    blast-radius guard
  guard-test.sh               15 fixtures proving the guard still works
modules/
  org-policy-baseline/        folder-scoped org policy, NIST-annotated
  audit-logging/              folder sink → GCS + Cloud Logging, asset feed
  project/                    project factory: APIs, audit config, budget, labels
  secure-network/             Shared VPC, NAT, hierarchical firewall, private DNS
stacks/
  0-bootstrap/ 1-foundation/ 2-projects/ 3-network/ 4-workload/
  1-org/                      organization-level baseline; refuses unless unlocked
docs/
  architecture.md             why folder-scoped, how the guard works, EFB deviations,
                              and how to run at the organization level instead
  org-setup.md                checklist: domain, Cloud Identity, second org, two identities
  control-mapping.md          NIST 800-53 Moderate: implemented / inherited / not, with gaps
  exam-notes.md               ACE → PCA notes tied to the resources in this repo
```

---

## Requirements

- `terraform` ≥ 1.9, `gcloud`, `jq`, `make`
- An org where you hold `roles/resourcemanager.folderCreator` and `roles/billing.user`
- Google provider `~> 8.4`

`make preflight` checks all of it and tells you exactly which grant is missing.

---

## Caveats worth knowing up front

- **KMS key rings and keys cannot be deleted in GCP.** `make lab-down` leaves them behind. Costs
  pennies; is permanent.
- **Project IDs are burned on delete.** Hence the random suffix in `modules/project`.
- **`make nuke` will refuse the state bucket and the folder** — both carry `prevent_destroy`.
  That is intentional.
- **This is not a compliance product.** Read
  [docs/control-mapping.md](docs/control-mapping.md), particularly the "Not implemented, and
  why" section, before repeating any claim about NIST in a room with an auditor in it.
