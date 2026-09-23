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
#   1. Organization-node writes — resources that write at an org, either because the type has
#      no folder-scoped form or because their parent names one. Refused outright unless
#      ORG_WRITES_ALLOWED_FOR names that exact organization. Catches the mistake of reaching
#      for stock Enterprise Foundation Blueprint code, which attaches org policy and log sinks
#      at the org, where every sibling folder inherits them, including ones it did not create.
#
#   2. Protected identifier — any planned change whose JSON so much as mentions a protected ID,
#      in either its before or after state. Deliberately blunt. A false positive here costs a
#      minute; a false negative costs an outage. Active regardless of layer 1.
#
# Layer 2 is the backstop, not the control. The real control is that no stack takes a parent
# above `folders/<playground>` unless you have deliberately named an organization that has
# nothing in it. See docs/architecture.md.

set -euo pipefail

STACK_DIR="${1:?usage: guard.sh <stack-dir> <plan-file>}"
PLAN_FILE="${2:?usage: guard.sh <stack-dir> <plan-file>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The environment beats config.env, so CI and scripts/guard-test.sh can drive this file
# hermetically.
#
# `${VAR+set}` rather than `${VAR:-}`: it distinguishes "exported as empty" from "not exported
# at all". That matters — a test asserting the default behaviour has to be able to say "empty,
# and I mean it" without config.env quietly supplying a value underneath.
#
# Both are captured BEFORE sourcing, because sourcing would otherwise overwrite whatever the
# caller just set. It silently did exactly that until the self-test caught it.
PROTECTED_IDS_WAS_SET="${PROTECTED_IDS+set}"
PROTECTED_IDS_FROM_ENV="${PROTECTED_IDS:-}"
ORG_ALLOW_WAS_SET="${ORG_WRITES_ALLOWED_FOR+set}"
ORG_ALLOW_FROM_ENV="${ORG_WRITES_ALLOWED_FOR:-}"

# shellcheck disable=SC1091
[[ -f "$REPO_ROOT/config.env" ]] && source "$REPO_ROOT/config.env"

[[ -n "$PROTECTED_IDS_WAS_SET" ]] && PROTECTED_IDS="$PROTECTED_IDS_FROM_ENV"
PROTECTED_IDS="${PROTECTED_IDS:-}"

# Which organization, if any, may receive writes at its own node.
#
# A specific numeric org ID, never a boolean. A boolean would be a switch you flip on for the
# lab and forget to flip back; an ID only ever unlocks the one organization you named, so
# pointing this repo at a different org re-locks it automatically with nothing to remember.
[[ -n "$ORG_ALLOW_WAS_SET" ]] && ORG_WRITES_ALLOWED_FOR="$ORG_ALLOW_FROM_ENV"
ORG_WRITES_ALLOWED_FOR="${ORG_WRITES_ALLOWED_FOR:-}"

if [[ -n "$ORG_WRITES_ALLOWED_FOR" && ! "$ORG_WRITES_ALLOWED_FOR" =~ ^[0-9]+$ ]]; then
  echo "guard: ORG_WRITES_ALLOWED_FOR must be a bare numeric org ID, got '$ORG_WRITES_ALLOWED_FOR'" >&2
  exit 1
fi

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

# --- Layer 1: writes at the organization node -----------------------------------------------
#
# Two kinds of resource reach the org node, and the type alone only tells you about the first:
#
#   a) Types with no folder-scoped form at all — google_organization_iam_*, org log sinks,
#      custom constraints. If one is in the plan, the plan writes at an org.
#   b) Types that take a parent and could go either way — google_org_policy_policy,
#      google_essential_contacts_contact, google_tags_tag_key. The parent decides.
#
# Both are collected here with the organization they target, and then judged against
# ORG_WRITES_ALLOWED_FOR:
#
#   unset            every org-node write is refused. This is the folder-scoped default and
#                    what you want in any organization that holds anything else.
#   set to an org ID org-node writes are permitted for THAT organization only. A write aimed
#                    anywhere else is still refused, so a config pointed at the wrong org fails
#                    closed rather than silently doing the thing it was built to prevent.
#
# A resource whose target organization cannot be determined is refused either way. Ambiguity
# fails closed; that is the whole job.
#
# google_folder is deliberately exempt. Creating the playground folder necessarily names an
# organization as its parent, and that is additive — it creates a child, it does not change
# anything the organization already applies to its existing children. An earlier version of this
# check blocked it and thereby made stage 1 permanently unrunnable.

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
      BAD_ORG+="  $addr  [$actions]  org could not be determined — refused"$'\n'
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

By default this stack is folder-scoped: every resource attaches at
folders/<playground> or below, so sibling folders cannot inherit anything it
sets. A plan that writes at the org node breaks that
guarantee for the whole organization at once.

If you are deliberately building the org-level variant, do it in an organization
that contains nothing you would miss, and set that organization's numeric ID in
config.env:

    ORG_WRITES_ALLOWED_FOR="123456789012"

That unlocks org-node writes for that organization and no other. It is not a
switch to flip on and off — pointing this repo at a different org re-locks it
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
