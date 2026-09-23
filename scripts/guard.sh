#!/usr/bin/env bash
#
# Blast-radius guard. Reads a saved Terraform plan and refuses it if it would write above the
# playground folder or touch anything on the protected list.
#
#   scripts/guard.sh <stack-dir> <plan-file>
#
# The Makefile runs this between `plan` and `apply`, and `apply` does not happen if it fails.
#
# Two independent layers, because they fail differently:
#
#   1. Resource type — a denylist of resources that can only ever write at the organization
#      node. Catches the mistake of reaching for stock Enterprise Foundation Blueprint code,
#      which attaches org policy and log sinks at the org, where every sibling folder inherits
#      them, including ones it did not create.
#
#   2. Protected identifier — any planned change whose JSON so much as mentions a protected ID.
#      Deliberately blunt. A false positive here costs a minute; a false negative costs an
#      outage.
#
# Layer 2 is the backstop, not the control. The real control is that no stack takes a
# parent above `folders/<playground>`. See docs/architecture.md.

set -euo pipefail

STACK_DIR="${1:?usage: guard.sh <stack-dir> <plan-file>}"
PLAN_FILE="${2:?usage: guard.sh <stack-dir> <plan-file>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# An explicitly exported PROTECTED_IDS beats config.env, so CI and scripts/guard-test.sh can
# override it. Captured BEFORE sourcing, because sourcing would otherwise overwrite the value
# the caller just set — which it silently did until the self-test caught it.
PROTECTED_IDS_FROM_ENV="${PROTECTED_IDS:-}"

# shellcheck disable=SC1091
[[ -f "$REPO_ROOT/config.env" ]] && source "$REPO_ROOT/config.env"

PROTECTED_IDS="${PROTECTED_IDS_FROM_ENV:-${PROTECTED_IDS:-}}"

command -v jq >/dev/null 2>&1 || { echo "guard: jq is required" >&2; exit 1; }

[[ -f "$STACK_DIR/$PLAN_FILE" ]] || { echo "guard: no plan at $STACK_DIR/$PLAN_FILE" >&2; exit 1; }

# A .json argument is read as-is. That is how scripts/guard-test.sh exercises this file against
# fixtures without needing a real cloud account, which in turn is why the guard can be trusted
# after someone edits it.
if [[ "$PLAN_FILE" == *.json ]]; then
  JSON="$(cat "$STACK_DIR/$PLAN_FILE")"
else
  JSON="$(cd "$STACK_DIR" && "${TF_BIN:-terraform}" show -json "$PLAN_FILE")"
fi

fail() { printf '\n\033[31mBLOCKED\033[0m  %s\n' "$1" >&2; }

VIOLATIONS=0

# --- Layer 1: organization-mutating resource types ----------------------------------------
#
# Unconditional. These resources have no folder-scoped form; if one is in the plan, the plan
# writes at the org node.
#
# Note on google_org_policy_custom_constraint: custom constraints are defined only at the org,
# so they are blocked here even though they are inert until a policy references them. That is a
# real capability lost to the folder-only rule, and it is documented as such.

DENIED_TYPES='[
  "google_organization_iam_binding",
  "google_organization_iam_member",
  "google_organization_iam_policy",
  "google_organization_iam_custom_role",
  "google_organization_iam_audit_config",
  "google_organization_policy",
  "google_org_policy_custom_constraint",
  "google_logging_organization_sink",
  "google_logging_organization_exclusion",
  "google_logging_organization_bucket_config",
  "google_cloud_asset_organization_feed",
  "google_compute_organization_security_policy",
  "google_compute_organization_security_policy_association",
  "google_compute_organization_security_policy_rule",
  "google_access_context_manager_access_policy",
  "google_billing_account_iam_binding",
  "google_billing_account_iam_member",
  "google_billing_account_iam_policy",
  "google_scc_organization_scc_big_query_export",
  "google_scc_notification_config",
  "google_scc_source",
  "google_scc_mute_config",
  "google_scc_posture",
  "google_scc_posture_deployment"
]'

TYPE_HITS="$(jq -r --argjson denied "$DENIED_TYPES" '
  [ .resource_changes[]?
    | select(.change.actions | any(. != "no-op" and . != "read"))
    | select(.type as $t | $denied | index($t))
    | "  \(.address)  [\(.change.actions | join(","))]"
  ] | .[]' <<<"$JSON")"

if [[ -n "$TYPE_HITS" ]]; then
  fail "plan writes at the organization node"
  echo "$TYPE_HITS" >&2
  VIOLATIONS=$((VIOLATIONS + 1))
fi

# --- Layer 1b: resources that are folder-scoped OR org-scoped depending on a value ----------
#
# These take a parent, so the type alone says nothing. The parent does.
#
# google_folder is deliberately NOT checked here. Creating the playground folder necessarily
# names the organization as its parent, and that is additive — it creates a child, it does not
# change anything the org already applies to its other children. An earlier version of this
# filter blocked it and thereby blocked stage 1 from ever running.

PARENT_HITS="$(jq -r '
  [ .resource_changes[]?
    | select(.change.actions | any(. != "no-op" and . != "read"))
    | select(.type | test("^google_(org_policy_policy|essential_contacts_contact|tags_tag_key)$"))
    | . as $rc
    | ( $rc.change.after // {} ) as $a
    | select(
        ( ($a.parent // "") | startswith("organizations/") ) or
        ( ($a.name   // "") | startswith("organizations/") )
      )
    | "  \($rc.address)  parent=\($a.parent // $a.name // $a.org_id)"
  ] | .[]' <<<"$JSON")"

if [[ -n "$PARENT_HITS" ]]; then
  fail "plan attaches a resource to the organization instead of the playground folder"
  echo "$PARENT_HITS" >&2
  VIOLATIONS=$((VIOLATIONS + 1))
fi

# --- Layer 2: protected identifiers --------------------------------------------------------
#
# Blunt on purpose. Anything mutating that mentions a protected ID anywhere in its planned
# values is refused, without trying to reason about whether the mention is harmless.
#
# BOTH before and after are inspected. A delete has `after: null`, so the identity of what is
# being destroyed exists only in `before` — and a delete is the single most dangerous action
# this guard can be asked to approve. An earlier version checked `after` alone and cheerfully
# permitted a plan that dropped a bucket out of the protected project; scripts/guard-test.sh
# has a case for it.

if [[ -z "${PROTECTED_IDS// /}" ]]; then
  printf '\033[33mnote\033[0m  PROTECTED_IDS is empty in config.env — the protected-identifier
'
  printf '      check is inactive. Org-node write blocking (layers 1 and 1b) is unaffected.
' >&2
fi

for protected in $PROTECTED_IDS; do
  ID_HITS="$(jq -r --arg id "$protected" '
    [ .resource_changes[]?
      | select(.change.actions | any(. != "no-op" and . != "read"))
      | select( ( ((.change.before // {}) | tostring) | contains($id) )
             or ( ((.change.after  // {}) | tostring) | contains($id) ) )
      | "  \(.address)  [\(.change.actions | join(","))]"
    ] | .[]' <<<"$JSON")"

  if [[ -n "$ID_HITS" ]]; then
    fail "plan touches protected identifier '$protected'"
    echo "$ID_HITS" >&2
    VIOLATIONS=$((VIOLATIONS + 1))
  fi
done

# --- Layer 3: deletes outside this stack's own resources -----------------------------------
#
# Advisory only. A destroy plan is full of deletes and that is the point, so this counts them
# and prints the number rather than refusing.

DELETES="$(jq -r '[ .resource_changes[]? | select(.change.actions | index("delete")) ] | length' <<<"$JSON")"

# --- Verdict -------------------------------------------------------------------------------

if [[ $VIOLATIONS -gt 0 ]]; then
  cat >&2 <<'EOF'

Nothing was applied.

This stack is folder-scoped by design: every resource attaches at
folders/<playground> or below, so that sibling folders cannot inherit anything
it sets. A plan that writes at the org node
breaks that guarantee for the whole organization at once.

If a resource genuinely has no folder-scoped form, it does not belong in this
repo. See docs/architecture.md, "Deviations from the stock EFB".
EOF
  exit 1
fi

CHANGES="$(jq -r '[ .resource_changes[]? | select(.change.actions | any(. != "no-op" and . != "read")) ] | length' <<<"$JSON")"
printf '\033[32mguard ok\033[0m  %s change(s), %s delete(s), 0 org-level writes\n' "$CHANGES" "$DELETES"
