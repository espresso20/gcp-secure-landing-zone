#!/usr/bin/env bash
#
# Everything that must be true before the first apply, checked in the order it will fail.
#
#   scripts/preflight.sh
#
# `make bootstrap` runs this first. It is cheap and it turns three separate five-minute
# failures into one thirty-second report.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILED=1; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

step "Tooling"
for t in terraform gcloud jq; do
  if command -v "$t" >/dev/null 2>&1; then
    ok "$t  $("$t" --version 2>/dev/null | head -1)"
  else
    bad "$t is not installed"
  fi
done

step "Configuration"
if [[ -f "$REPO_ROOT/config.env" ]]; then
  ok "config.env exists"
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/config.env"
  set +a

  [[ -n "${TF_VAR_org_id:-}" ]]          && ok "org_id          $TF_VAR_org_id"          || bad "TF_VAR_org_id is empty (make ids)"
  [[ -n "${TF_VAR_billing_account:-}" ]] && ok "billing_account $TF_VAR_billing_account" || bad "TF_VAR_billing_account is empty (make ids)"
  [[ -n "${TF_VAR_prefix:-}" ]]          && ok "prefix          $TF_VAR_prefix"          || bad "TF_VAR_prefix is empty"

  if [[ -n "${TF_VAR_prefix:-}" ]] && ! [[ "$TF_VAR_prefix" =~ ^[a-z][a-z0-9]{2,9}$ ]]; then
    bad "prefix '$TF_VAR_prefix' must be 3-10 lowercase alphanumerics starting with a letter"
  fi

  [[ -n "${TF_VAR_customer_id:-}" ]] \
    && ok "customer_id     $TF_VAR_customer_id" \
    || warn "TF_VAR_customer_id empty — domain-restricted sharing (AC-3/AC-20) will be skipped"
else
  bad "config.env not found — run: make init-config"
fi

step "Credentials"
if gcloud auth print-access-token >/dev/null 2>&1; then
  ok "gcloud  $(gcloud config get-value account 2>/dev/null)"
else
  bad "gcloud token expired — run: make auth"
fi

if gcloud auth application-default print-access-token >/dev/null 2>&1; then
  ok "application default credentials"
else
  bad "ADC expired — run: make auth  (this is what Terraform uses)"
fi

step "Authorization"
if [[ -n "${TF_VAR_org_id:-}" ]]; then
  if gcloud organizations describe "$TF_VAR_org_id" >/dev/null 2>&1; then
    ok "can read organization $TF_VAR_org_id"
  else
    bad "cannot read organization $TF_VAR_org_id — wrong ID, or missing organizationViewer"
  fi

  # Stage 0 creates a folder directly under the org. Without this role it fails at the very
  # first resource, several API calls in.
  if gcloud organizations get-iam-policy "$TF_VAR_org_id" --format=json 2>/dev/null \
       | jq -e --arg u "user:$(gcloud config get-value account 2>/dev/null)" '
           [ .bindings[]? | select(.members | index($u))
             | select(.role | test("folderCreator|folderAdmin|resourcemanager.folderAdmin|owner|admin"; "i")) ]
           | length > 0' >/dev/null 2>&1; then
    ok "have a folder-creating role at the organization"
  else
    warn "could not confirm roles/resourcemanager.folderCreator — stage 0 may fail"
    warn "  grant with: gcloud organizations add-iam-policy-binding $TF_VAR_org_id \\"
    warn "    --member=\"user:\$(gcloud config get-value account)\" --role=\"roles/resourcemanager.folderCreator\""
  fi
fi

if [[ -n "${TF_VAR_billing_account:-}" ]]; then
  if gcloud billing accounts describe "$TF_VAR_billing_account" >/dev/null 2>&1; then
    ok "can read billing account $TF_VAR_billing_account"
  else
    bad "cannot read billing account $TF_VAR_billing_account — wrong ID, or missing roles/billing.user"
  fi
fi

step "Blast radius"
PROTECTED_IDS="${PROTECTED_IDS:-}"
ok "protected identifiers: $PROTECTED_IDS"
if [[ "${GCP_SEED_PROJECT:-}" != "" ]]; then
  for p in $PROTECTED_IDS; do
    if [[ "$GCP_SEED_PROJECT" == "$p" ]]; then
      bad "GCP_SEED_PROJECT is a protected project — refusing"
    fi
  done
fi
if "$REPO_ROOT/scripts/guard-test.sh" >/dev/null 2>&1; then
  ok "guard self-test passes"
else
  bad "guard self-test FAILED — do not apply until scripts/guard.sh is fixed (make guard-test)"
fi

# --- Verdict ------------------------------------------------------------------------------

if [[ $FAILED -eq 0 ]]; then
  printf '\n\033[32mPreflight clean.\033[0m\n'
  exit 0
fi

printf '\n\033[31mPreflight failed.\033[0m Fix the marked items above before applying.\n'
exit 1
