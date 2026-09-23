#!/usr/bin/env bash
#
# Reads a saved Terraform plan and refuses it if it would write above the playground folder or
# touch anything on the protected list.
#
#   scripts/guard.sh <stack-dir> <plan-file>
#
# scripts/tf.sh runs this between plan and apply; apply does not happen if it fails.
#
#   Layer 1  org-node writes, refused unless ORG_WRITES_ALLOWED_FOR names that exact org
#   Layer 2  any change mentioning a protected ID, before or after state
#   Layer 3  deletes, counted and reported only
#
# Layer 2 is a backstop. The control is that no stack takes a parent above the playground
# folder. See docs/architecture.md.

set -euo pipefail

STACK_DIR="${1:?usage: guard.sh <stack-dir> <plan-file>}"
PLAN_FILE="${2:?usage: guard.sh <stack-dir> <plan-file>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The environment beats config.env so tests and CI can drive this hermetically.
#
# `${VAR+set}` rather than `${VAR:-}` distinguishes "exported as empty" from "not exported",
# which a test asserting the default behaviour needs. Captured before sourcing, since sourcing
# would otherwise overwrite what the caller just set.
PROTECTED_IDS_WAS_SET="${PROTECTED_IDS+set}"
PROTECTED_IDS_FROM_ENV="${PROTECTED_IDS:-}"
ORG_ALLOW_WAS_SET="${ORG_WRITES_ALLOWED_FOR+set}"
ORG_ALLOW_FROM_ENV="${ORG_WRITES_ALLOWED_FOR:-}"

# shellcheck disable=SC1091
[[ -f "$REPO_ROOT/config.env" ]] && source "$REPO_ROOT/config.env"

[[ -n "$PROTECTED_IDS_WAS_SET" ]] && PROTECTED_IDS="$PROTECTED_IDS_FROM_ENV"
PROTECTED_IDS="${PROTECTED_IDS:-}"

# Which organization, if any, may receive writes at its own node. An ID rather than a boolean,
# so pointing this repo at a different org re-locks it with nothing to remember.
[[ -n "$ORG_ALLOW_WAS_SET" ]] && ORG_WRITES_ALLOWED_FOR="$ORG_ALLOW_FROM_ENV"
ORG_WRITES_ALLOWED_FOR="${ORG_WRITES_ALLOWED_FOR:-}"

if [[ -n "$ORG_WRITES_ALLOWED_FOR" && ! "$ORG_WRITES_ALLOWED_FOR" =~ ^[0-9]+$ ]]; then
  echo "guard: ORG_WRITES_ALLOWED_FOR must be a bare numeric org ID, got '$ORG_WRITES_ALLOWED_FOR'" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "guard: jq is required" >&2; exit 1; }

[[ -f "$STACK_DIR/$PLAN_FILE" ]] || { echo "guard: no plan at $STACK_DIR/$PLAN_FILE" >&2; exit 1; }

# A .json argument is read as-is, which is how guard-test.sh drives this without a cloud
# account.
if [[ "$PLAN_FILE" == *.json ]]; then
  JSON="$(cat "$STACK_DIR/$PLAN_FILE")"
else
  JSON="$(cd "$STACK_DIR" && "${TF_BIN:-terraform}" show -json "$PLAN_FILE")"
fi

fail() { printf '\n\033[31mBLOCKED\033[0m  %s\n' "$1" >&2; }

VIOLATIONS=0

# Layer 1: writes at the organization node.
#
# Two kinds of resource get here. Some types have no folder-scoped form (google_organization_iam_*,
# org log sinks, custom constraints). Others take a parent that could name either, so the parent
# decides. Both are collected with the org they target and checked against ORG_WRITES_ALLOWED_FOR:
# unset refuses everything, set permits that one organization only.
#
# A resource whose target org cannot be determined is refused either way.
#
# google_folder is exempt. Creating the playground folder names an organization as its parent,
# but that is additive and changes nothing for the org's existing children. Blocking it made
# stage 1 unrunnable in an earlier version of this check.

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

# Emits one TAB-separated "address  actions  orgid" line per org-touching change. orgid is
# empty when it could not be established.
ORG_HITS="$(jq -r --argjson denied "$DENIED_TYPES" '
  def orgid:
    (.change.after // {}) as $a
    | (($a.org_id // "") | tostring) as $direct
    | if $direct != "" then $direct
      else ([ ($a | tostring) | scan("organizations/([0-9]+)") ] | flatten | first // "")
      end;

  [ .resource_changes[]?
    | select(.change.actions | any(. != "no-op" and . != "read"))
    | select(.type != "google_folder")
    | select(
        ((.type as $t | $denied | index($t)) != null)
        or ((((.change.after // {}).parent // "") | tostring) | startswith("organizations/"))
        or ((((.change.after // {}).name   // "") | tostring) | startswith("organizations/"))
      )
    | "\(.address)\t\(.change.actions | join(","))\t\(orgid)"
  ] | .[]' <<<"$JSON")"

if [[ -n "$ORG_HITS" ]]; then
  BAD_ORG=""
  while IFS=$'\t' read -r addr actions orgid; do
    [[ -z "$addr" ]] && continue
    if [[ -z "$ORG_WRITES_ALLOWED_FOR" ]]; then
      BAD_ORG+="  $addr  [$actions]  org=${orgid:-<undetermined>}"$'\n'
    elif [[ -z "$orgid" ]]; then
      BAD_ORG+="  $addr  [$actions]  org could not be determined, refused"$'\n'
    elif [[ "$orgid" != "$ORG_WRITES_ALLOWED_FOR" ]]; then
      BAD_ORG+="  $addr  [$actions]  targets org $orgid, allowed org is $ORG_WRITES_ALLOWED_FOR"$'\n'
    fi
  done <<<"$ORG_HITS"

  if [[ -n "$BAD_ORG" ]]; then
    if [[ -z "$ORG_WRITES_ALLOWED_FOR" ]]; then
      fail "plan writes at the organization node, and no organization is allowed"
    else
      fail "plan writes at an organization other than the one allowed"
    fi
    printf '%s' "$BAD_ORG" >&2
    VIOLATIONS=$((VIOLATIONS + 1))
  else
    ALLOWED_ORG_WRITES="$(printf '%s' "$ORG_HITS" | grep -c . || true)"
  fi
fi

# Layer 2: protected identifiers.
#
# Blunt on purpose: any mutating change mentioning a protected ID is refused, without trying to
# decide whether the mention is harmless.
#
# Both before and after are inspected. A delete has `after: null`, so what is being destroyed
# is named only in `before`. Checking `after` alone let a delete through; guard-test.sh covers
# that case.

if [[ -z "${PROTECTED_IDS// /}" ]]; then
  printf '\033[33mnote\033[0m  PROTECTED_IDS is empty in config.env. The protected-identifier
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

# Layer 3: deletes. Counted and reported, not refused; a destroy plan is meant to be full of
# them.

DELETES="$(jq -r '[ .resource_changes[]? | select(.change.actions | index("delete")) ] | length' <<<"$JSON")"

# Verdict

if [[ $VIOLATIONS -gt 0 ]]; then
  cat >&2 <<'EOF'

Nothing was applied.

By default this stack is folder-scoped: every resource attaches at
folders/<playground> or below, so sibling folders cannot inherit anything it
sets. A plan that writes at the org node breaks that
guarantee for the whole organization at once.

If you are deliberately building the org-level variant, do it in an organization
that contains nothing you would miss, and set that organization's numeric ID in
config.env:

    ORG_WRITES_ALLOWED_FOR="123456789012"

That unlocks org-node writes for that organization and no other. It is not a
switch to flip on and off. Pointing this repo at a different org re-locks it
with nothing for you to remember.

See docs/architecture.md, "Running at the organization level".
EOF
  exit 1
fi

CHANGES="$(jq -r '[ .resource_changes[]? | select(.change.actions | any(. != "no-op" and . != "read")) ] | length' <<<"$JSON")"

if [[ -n "${ALLOWED_ORG_WRITES:-}" && "${ALLOWED_ORG_WRITES:-0}" -gt 0 ]]; then
  printf '\033[32mguard ok\033[0m  %s change(s), %s delete(s), %s org-level write(s) to org %s\n' \
    "$CHANGES" "$DELETES" "$ALLOWED_ORG_WRITES" "$ORG_WRITES_ALLOWED_FOR"
else
  printf '\033[32mguard ok\033[0m  %s change(s), %s delete(s), 0 org-level writes\n' "$CHANGES" "$DELETES"
fi
