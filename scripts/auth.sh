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
# On top of the tokens it checks three things that are not credentials but fail the same way:
# whether this account can see the organization named in config.env, whether it can see a
# billing account, and — the important one once you have more than one org — whether ADC and
# gcloud are actually the same identity.
#
# That last one deserves saying plainly: named gcloud configurations are per-configuration,
# but Application Default Credentials are GLOBAL. `gcloud config configurations activate lab`
# changes what gcloud does and does not touch ADC at all. Terraform uses ADC. So it is entirely
# possible to have gcloud pointed at one organization while Terraform is still authenticated
# against another, with nothing on screen to suggest it. This script refuses to pass in that
# state.
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
WANT_CONFIG="${GCLOUD_CONFIGURATION:-}"
WANT_ORG="${TF_VAR_org_id:-}"

# --- gcloud configuration ------------------------------------------------------------------
#
# Set GCLOUD_CONFIGURATION in config.env when this checkout targets a specific org. Activating
# it here means the rest of the script, and everything you run afterwards in this shell, is
# talking to the account you meant.

if [[ -n "$WANT_CONFIG" ]]; then
  CURRENT_CONFIG="$(gcloud config configurations list --filter='is_active=true' \
                      --format='value(name)' 2>/dev/null | head -1)"
  if [[ "$CURRENT_CONFIG" != "$WANT_CONFIG" ]]; then
    if gcloud config configurations describe "$WANT_CONFIG" >/dev/null 2>&1; then
      gcloud config configurations activate "$WANT_CONFIG" >/dev/null 2>&1 \
        && ok "activated gcloud configuration '$WANT_CONFIG' (was '${CURRENT_CONFIG:-none}')"
    else
      echo "config.env names GCLOUD_CONFIGURATION='$WANT_CONFIG' but no such configuration exists." >&2
      echo "Create it with:  gcloud config configurations create $WANT_CONFIG" >&2
      exit 1
    fi
  else
    ok "gcloud configuration '$WANT_CONFIG'"
  fi
fi

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

# Which identity ADC actually belongs to.
#
# The credentials file does not record it — for user credentials it holds a refresh token and
# nothing human-readable — so the only way to find out is to ask Google what the token is. This
# is the check that catches "gcloud says one org, Terraform means another".
adc_identity() {
  local token
  token="$(gcloud auth application-default print-access-token 2>/dev/null)" || return 1
  [[ -n "$token" ]] || return 1
  curl -s --max-time 10 "https://oauth2.googleapis.com/tokeninfo?access_token=${token}" 2>/dev/null \
    | sed -n 's/.*"email"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1
}

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

# --- Identity consistency ------------------------------------------------------------------
#
# Before asking what this account can see, establish that "this account" means one thing.

GCLOUD_ACCT="$(gcloud config get-value account 2>/dev/null)"
ADC_ACCT="$(adc_identity)"
I_OK=1

if [[ -z "$ADC_ACCT" ]]; then
  warn "could not determine which identity ADC belongs to (offline?) — skipping the match check"
elif [[ "$ADC_ACCT" == "$GCLOUD_ACCT" ]]; then
  ok "gcloud and ADC are both $GCLOUD_ACCT"
else
  bad "gcloud is $GCLOUD_ACCT but ADC is $ADC_ACCT"
  bad "  Terraform would run as $ADC_ACCT, not as the account gcloud shows."
  I_OK=0
fi

probe_org     && O_OK=1 || O_OK=0
probe_billing && B_OK=1 || B_OK=0

# --- Org match ---------------------------------------------------------------------------------
#
# config.env names an org. If this identity cannot see that specific one, stop — whatever comes
# next would build in the wrong place.

M_OK=1
if [[ -n "$WANT_ORG" ]]; then
  if gcloud organizations describe "$WANT_ORG" >/dev/null 2>&1; then
    ok "config.env org     $WANT_ORG is visible to this account"
  else
    bad "config.env names org $WANT_ORG, which this account cannot see"
    M_OK=0
  fi
fi

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

if [[ $G_OK == 1 && $A_OK == 1 && $O_OK == 1 && $B_OK == 1 && $I_OK == 1 && $M_OK == 1 ]]; then
  step "Ready. Terraform and gcloud will both work, as the same identity."
  exit 0
fi

step "Not ready."

[[ $G_OK == 0 || $A_OK == 0 ]] && echo "  Tokens: try  scripts/auth.sh --force"

[[ $I_OK == 0 ]] && cat <<'HINT'
  gcloud and ADC are different identities. Named configurations are per-configuration;
  Application Default Credentials are global and shared across all of them. Terraform reads
  ADC, so it is currently authenticated as the wrong account.

  Re-issue ADC as the account you actually want:

      gcloud auth application-default login

  This overwrites ADC for every configuration, which is the whole problem — whichever org you
  authenticate last is the one Terraform will build in, regardless of what gcloud reports.
HINT

[[ $M_OK == 0 ]] && cat <<'HINT'
  The organization named in config.env is not visible to this identity. Either config.env
  belongs to a different checkout, or the wrong gcloud configuration is active.

      gcloud config configurations list
      gcloud organizations list
HINT

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
