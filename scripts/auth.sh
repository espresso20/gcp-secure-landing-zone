#!/usr/bin/env bash
#
# Sign in to everything this stack needs, in one go.
#
# Two credentials that expire independently, which is why signing in always seems to half-work:
#
#   gcloud user   what gcloud commands use
#   ADC           what Terraform uses. Different token, different expiry, so gcloud can work
#                 perfectly while `terraform plan` returns 403.
#
# It also checks three things that are not credentials but fail the same way: whether this
# account can see the org named in config.env, whether it can see a billing account, and
# whether ADC and gcloud are the same identity.
#
# That last one matters because gcloud configurations are per-configuration while ADC is
# global. `gcloud config configurations activate lab` does not touch ADC, and Terraform reads
# ADC, so gcloud can point at one org while Terraform is authenticated against another.
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
    # Prints the header block, so --help cannot drift out of step with the file.
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

# config.env is optional here: before `make bootstrap` there is no seed project to point at,
# and requiring one would be circular.

# shellcheck disable=SC1091
[[ -f "$REPO_ROOT/config.env" ]] && source "$REPO_ROOT/config.env"

SEED_PROJECT="${GCP_SEED_PROJECT:-}"
PROTECTED_IDS="${PROTECTED_IDS:-}"
WANT_CONFIG="${GCLOUD_CONFIGURATION:-}"
WANT_ORG="${TF_VAR_org_id:-}"

# Activating the configuration here means the rest of this script, and everything you run
# afterwards in this shell, talks to the account you meant.

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

# The quota project must never be a protected one, and the active gcloud project is left
# alone: every stack names its project explicitly, and a shell silently repointed at the wrong
# project fails by succeeding.
for protected in $PROTECTED_IDS; do
  if [[ "$SEED_PROJECT" == "$protected" ]]; then
    echo "refusing to run: GCP_SEED_PROJECT is set to the protected project '$protected'" >&2
    echo "fix config.env; this stack must never target it" >&2
    exit 1
  fi
done

# Each probe asks for something only a live credential can produce. A config file will happily
# describe a token that expired days ago.

# Not `[[ -r /dev/tty ]]`: that returns true in shells where opening it then fails with
# "Device not configured". The only reliable test is to open it.
can_prompt() { (exec 3</dev/tty) 2>/dev/null; }

probe_gcloud() { gcloud auth print-access-token >/dev/null 2>&1; }
probe_adc()    { gcloud auth application-default print-access-token >/dev/null 2>&1; }

# Which identity ADC belongs to. The credentials file does not record it (for user credentials it holds a refresh token and
# nothing human-readable), so the only way to find out is to ask Google about the token.
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

# ADC with no quota project returns a 403 naming a disabled service rather than a missing
# setting ("SERVICE_DISABLED: Cloud Resource Manager API has not been used in project ..."),
# which sends you off enabling APIs that are already on. Idempotent, so it runs every time.

if [[ -n "$SEED_PROJECT" ]]; then
  if gcloud auth application-default set-quota-project "$SEED_PROJECT" >/dev/null 2>&1; then
    ok "ADC quota project set to $SEED_PROJECT"
  else
    bad "could not set the ADC quota project to $SEED_PROJECT; Terraform may 403"
  fi
else
  warn "GCP_SEED_PROJECT not set yet, skipping quota project (expected before 'make bootstrap')"
fi

# A live token that cannot see the org looks exactly like success until stage 0 tries to
# create a folder.

step "Checking access"

# Before asking what this account can see, establish that it means one thing.

GCLOUD_ACCT="$(gcloud config get-value account 2>/dev/null)"
ADC_ACCT="$(adc_identity)"
I_OK=1

if [[ -z "$ADC_ACCT" ]]; then
  warn "could not determine which identity ADC belongs to (offline?), skipping the match check"
elif [[ "$ADC_ACCT" == "$GCLOUD_ACCT" ]]; then
  ok "gcloud and ADC are both $GCLOUD_ACCT"
else
  bad "gcloud is $GCLOUD_ACCT but ADC is $ADC_ACCT"
  bad "  Terraform would run as $ADC_ACCT, not as the account gcloud shows."
  I_OK=0
fi

probe_org     && O_OK=1 || O_OK=0
probe_billing && B_OK=1 || B_OK=0

# config.env names an org. If this identity cannot see that one, stop.

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

# Re-probe rather than assume: a login command can exit 0 having done nothing useful.

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

  This overwrites ADC for every configuration, so whichever org you authenticate last is the
  one Terraform builds in, regardless of what gcloud reports.
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
  https://console.cloud.google.com/billing. You need roles/billing.user on it.
HINT

exit 1
