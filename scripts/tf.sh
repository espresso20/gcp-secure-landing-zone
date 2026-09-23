#!/usr/bin/env bash
#
# Terraform wrapper. The Makefile calls this; you generally should not need to.
#
#   scripts/tf.sh <stack> <action> [extra terraform args]
#
# It exists so that no target has to cd, remember a backend prefix, or remember to run the
# guard. Specifically it handles:
#
#   * sourcing config.env and exporting the TF_VAR_* the stacks expect
#   * partial backend configuration, so no state location is committed
#   * stage 0 running on local state (it creates the bucket the others use)
#   * running scripts/guard.sh between plan and apply, every time, with no way to skip it
#   * a shared provider plugin cache, so five stacks do not download five copies

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="${1:?usage: tf.sh <stack> <action> [args...]}"
ACTION="${2:?usage: tf.sh <stack> <action> [args...]}"
shift 2

STACK_DIR="$REPO_ROOT/stacks/$STACK"
PLAN_FILE="tfplan"

TF="${TF_BIN:-terraform}"

step() { printf '\n\033[1m[%s]\033[0m %s\n' "$STACK" "$1"; }
die()  { printf '\n\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

[[ -d "$STACK_DIR" ]] || die "no such stack: $STACK  (try: make stacks)"

# --- Configuration ---------------------------------------------------------------------------

# fmt and validate are static checks. They must work in a fresh clone, before anyone has an
# account configured — otherwise CI cannot lint the repo and neither can a reviewer.
NEEDS_CONFIG=1
case "$ACTION" in fmt|validate) NEEDS_CONFIG=0 ;; esac

if [[ -f "$REPO_ROOT/config.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/config.env"
  set +a
elif [[ $NEEDS_CONFIG -eq 1 ]]; then
  die "config.env not found. Run: make init-config"
fi

# The stacks declare `seed_project` and `state_bucket`; config.env stores the seed project
# under a non-TF_VAR name because scripts/auth.sh needs it too, before Terraform is involved.
export TF_VAR_seed_project="${GCP_SEED_PROJECT:-}"
export TF_VAR_state_bucket="${TF_VAR_state_bucket:-}"

# Shared plugin cache. Five stacks, one download.
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$REPO_ROOT/.terraform-cache}"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

export TF_IN_AUTOMATION=1

# --- Required inputs per action ------------------------------------------------------------------

require_var() {
  local name="$1" hint="$2"
  [[ -n "${!name:-}" ]] || die "$name is not set in config.env — $hint"
}

if [[ "$ACTION" != "fmt" && "$ACTION" != "validate" ]]; then
  require_var TF_VAR_org_id          "run 'make ids' to find it"
  require_var TF_VAR_billing_account "run 'make ids' to find it"
  require_var TF_VAR_prefix          "pick a 3-10 char lowercase prefix"
fi

# Stage 0 is the exception: it creates the bucket, so it cannot require one.
if [[ "$STACK" != "0-bootstrap" && "$ACTION" != "fmt" && "$ACTION" != "validate" ]]; then
  require_var TF_VAR_state_bucket "run 'make bootstrap' first"
  require_var TF_VAR_folder_id    "run 'make bootstrap' first"
  require_var GCP_SEED_PROJECT    "run 'make bootstrap' first"
fi

# --- Backend ----------------------------------------------------------------------------------------

init_stack() {
  local extra=()
  if [[ "$STACK" == "0-bootstrap" ]]; then
    # No backend block in this stack at all until migration; nothing to configure.
    :
  else
    extra=(
      -backend-config="bucket=$TF_VAR_state_bucket"
      -backend-config="prefix=$STACK"
    )
  fi
  ( cd "$STACK_DIR" && "$TF" init -input=false "${extra[@]}" "$@" )
}

ensure_init() {
  if [[ ! -d "$STACK_DIR/.terraform" ]]; then
    step "initializing"
    init_stack
  fi
}

# Static validation does not need — and must not require — a reachable state bucket.
ensure_init_local() {
  ( cd "$STACK_DIR" && "$TF" init -backend=false -input=false >/dev/null )
}

# --- Actions --------------------------------------------------------------------------------------------

case "$ACTION" in

  init)
    step "init"
    init_stack "$@"
    ;;

  reinit)
    step "reconfiguring backend"
    init_stack -reconfigure "$@"
    ;;

  fmt)
    ( cd "$STACK_DIR" && "$TF" fmt -recursive "$@" )
    ;;

  validate)
    ensure_init_local
    step "validate"
    ( cd "$STACK_DIR" && "$TF" validate "$@" )
    ;;

  plan)
    ensure_init
    step "plan"
    ( cd "$STACK_DIR" && "$TF" plan -input=false -out="$PLAN_FILE" "$@" )
    step "checking blast radius"
    "$REPO_ROOT/scripts/guard.sh" "$STACK_DIR" "$PLAN_FILE"
    ;;

  apply)
    ensure_init
    # Always re-plan. Applying a stale plan file is how you apply something you did not read.
    step "plan"
    ( cd "$STACK_DIR" && "$TF" plan -input=false -out="$PLAN_FILE" "$@" )
    step "checking blast radius"
    "$REPO_ROOT/scripts/guard.sh" "$STACK_DIR" "$PLAN_FILE"
    step "apply"
    ( cd "$STACK_DIR" && "$TF" apply -input=false "$PLAN_FILE" )
    ;;

  destroy)
    ensure_init
    step "destroy plan"
    ( cd "$STACK_DIR" && "$TF" plan -destroy -input=false -out="$PLAN_FILE" "$@" )
    step "checking blast radius"
    "$REPO_ROOT/scripts/guard.sh" "$STACK_DIR" "$PLAN_FILE"
    step "destroy"
    ( cd "$STACK_DIR" && "$TF" apply -input=false "$PLAN_FILE" )
    ;;

  output)
    ensure_init
    ( cd "$STACK_DIR" && "$TF" output "$@" )
    ;;

  show)
    ensure_init
    ( cd "$STACK_DIR" && "$TF" show "$@" )
    ;;

  console)
    ensure_init
    ( cd "$STACK_DIR" && "$TF" console "$@" )
    ;;

  state)
    ensure_init
    ( cd "$STACK_DIR" && "$TF" state "$@" )
    ;;

  refresh)
    ensure_init
    ( cd "$STACK_DIR" && "$TF" apply -refresh-only -input=false "$@" )
    ;;

  *)
    die "unknown action: $ACTION"
    ;;
esac
