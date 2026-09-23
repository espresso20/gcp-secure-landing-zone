#!/usr/bin/env bash
#
# Sign in to everything this stack needs, in one go.
#
# Two credentials, and they expire independently, which is why signing in always seems to
# half-work:
#
#   1. gcloud user      — what `gcloud` commands use. `gcloud auth login`.
#   2. ADC              — what Terraform uses. Different token, different expiry, and a source
#                         of real confusion because `gcloud` can be working perfectly while
#                         `terraform plan` returns 403.
#
# On top of the tokens it checks two things that are not credentials but fail the same way:
# whether this account can see the organization, and whether it can see a billing account.
# Without those, `make bootstrap` gets several minutes in and then dies.
#
# By default this checks everything and only prompts for what is actually dead.
#
#   scripts/auth.sh            sign in to whatever has expired
#   scripts/auth.sh --check    report status and change nothing
#   scripts/auth.sh --force    sign in again regardless
#
# Each sign-in opens a browser.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="auto"

for arg in "$@"; do
  case "$arg" in
    --check) MODE="check" ;;
    --force) MODE="force" ;;
    # Prints the header comment and stops at the first line that is not one, so the help
    # cannot drift out of step with the file the way a hardcoded line range does.
    -h|--help) awk 'NR>1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "$1 is not installed or not on PATH" >&2
    exit 1
  }
}
need gcloud

# --- Configuration ------------------------------------------------------------------------
#
# config.env is optional here. Before `make bootstrap` has ever run there is no seed project
# to point at, and refusing to authenticate until one exists would be a circular dependency.

# shellcheck disable=SC1091
[[ -f "$REPO_ROOT/config.env" ]] && source "$REPO_ROOT/config.env"

SEED_PROJECT="${GCP_SEED_PROJECT:-}"
PROTECTED_IDS="${PROTECTED_IDS:-}"

# The quota project must never be a protected one.
#
# A single-project version of this script can reasonably hardcode its project and set it active
# on every run. This one must not. Pointing every subsequent gcloud and Terraform call at a
# project that came from a config-file default is precisely the outcome this repo is arranged to
# prevent, so the value is checked rather than assumed.
for protected in $PROTECTED_IDS; do
  if [[ "$SEED_PROJECT" == "$protected" ]]; then
    echo "refusing to run: GCP_SEED_PROJECT is set to the protected project '$protected'" >&2
    echo "fix config.env — this stack must never target it" >&2
    exit 1
  fi
done

# --- Probes -------------------------------------------------------------------------------
#
# Each probe asks for something only a live credential can produce. Nothing here trusts a
# config file, because a config file will happily describe a token that expired days ago.

# Whether this shell can actually read from a human.
#
# Not `[[ -r /dev/tty ]]`: that returns true in shells where opening it then fails with "Device
# not configured". The only reliable test is to open it.
can_prompt() { (exec 3</dev/tty) 2>/dev/null; }

probe_gcloud() { gcloud auth print-access-token >/dev/null 2>&1; }
probe_adc()    { gcloud auth application-default print-access-token >/dev/null 2>&1; }

# Not credentials, but they fail a `make bootstrap` just as dead.
probe_org() {
  [[ -n "$(gcloud organizations list --format='value(name)' 2>/dev/null | head -1)" ]]
}
probe_billing() {
  [[ -n "$(gcloud billing accounts list --filter='open=true' \
             --format='value(name)' 2>/dev/null | head -1)" ]]
}

# --- Status -------------------------------------------------------------------------------

step "Checking credentials"

probe_gcloud && G_OK=1 || G_OK=0
probe_adc    && A_OK=1 || A_OK=0

report_creds() {
  [[ $G_OK == 1 ]] && ok  "gcloud user      $(gcloud config get-value account 2>/dev/null)" \
                   || bad "gcloud user      expired"
  [[ $A_OK == 1 ]] && ok  "application default credentials" \
                   || bad "application default credentials  expired  (this is what Terraform uses)"
}
report_creds

if [[ "$MODE" == "check" ]]; then
  [[ $G_OK == 1 && $A_OK == 1 ]] && exit 0 || exit 1
fi

if [[ "$MODE" == "auto" && $G_OK == 1 && $A_OK == 1 ]]; then
  step "Credentials are live."
else
  # --- Sign in ----------------------------------------------------------------------------

  if [[ "$MODE" == "force" || $G_OK == 0 ]]; then
    step "1/2  gcloud user account"
    gcloud auth login || { echo "gcloud auth login failed" >&2; exit 1; }
  fi

  if [[ "$MODE" == "force" || $A_OK == 0 ]]; then
    step "2/2  application default credentials"
    echo "  Terraform uses these. Separate from the login above."
    gcloud auth application-default login || {
      echo "application-default login failed" >&2
      exit 1
    }
  fi
fi

# --- Quota project ------------------------------------------------------------------------
#
# ADC with no quota project produces a 403 that names a disabled service rather than a missing
# setting — "SERVICE_DISABLED: Cloud Resource Manager API has not been used in project ..." —
# and sends you off enabling APIs that are already enabled. Setting it is idempotent, so it
# happens on every run.
#
# Unlike the original, the active gcloud project is deliberately left alone. Every Terraform
# stack here names its project explicitly, and a shell silently repointed at the wrong project
# is a worse failure than an expired token because it succeeds.

if [[ -n "$SEED_PROJECT" ]]; then
  if gcloud auth application-default set-quota-project "$SEED_PROJECT" >/dev/null 2>&1; then
    ok "ADC quota project set to $SEED_PROJECT"
  else
    bad "could not set the ADC quota project to $SEED_PROJECT — Terraform may 403"
  fi
else
  warn "GCP_SEED_PROJECT not set yet — skipping quota project (expected before 'make bootstrap')"
fi

# --- Authorization ------------------------------------------------------------------------
#
# A live token that cannot see the org is the failure mode this section exists for. It looks
# exactly like success until stage 0 tries to create a folder.

step "Checking access"

probe_org     && O_OK=1 || O_OK=0
probe_billing && B_OK=1 || B_OK=0

if [[ $O_OK == 1 ]]; then
  ok "organization    $(gcloud organizations list --format='value(displayName,name)' 2>/dev/null | head -1 | tr '\t' ' ')"
else
  bad "organization    not visible to this account"
fi

if [[ $B_OK == 1 ]]; then
  ok "billing account $(gcloud billing accounts list --filter='open=true' --format='value(displayName,name)' 2>/dev/null | head -1 | tr '\t' ' ')"
else
  bad "billing account no open billing account visible to this account"
fi

# --- Verify -------------------------------------------------------------------------------
#
# Re-probe rather than assume. A login command can exit 0 having done nothing useful, and the
# whole point of this script is to stop finding that out from a failed apply.

step "Verifying"

probe_gcloud && G_OK=1 || G_OK=0
probe_adc    && A_OK=1 || A_OK=0
report_creds

if [[ $G_OK == 1 && $A_OK == 1 && $O_OK == 1 && $B_OK == 1 ]]; then
  step "Ready. Terraform and gcloud will both work."
  exit 0
fi

step "Not ready."

[[ $G_OK == 0 || $A_OK == 0 ]] && echo "  Tokens: try  scripts/auth.sh --force"

[[ $O_OK == 0 ]] && cat <<'HINT'
  Organization not visible. Either this account is outside the org, or it is missing
  roles/resourcemanager.organizationViewer. An org admin can grant it with:

      gcloud organizations add-iam-policy-binding <ORG_ID> \
        --member="user:<you>" --role="roles/resourcemanager.organizationViewer"
HINT

[[ $B_OK == 0 ]] && cat <<'HINT'
  No open billing account. Stage 0 cannot create projects without one. Check
  https://console.cloud.google.com/billing — you need roles/billing.user on it.
HINT

exit 1
