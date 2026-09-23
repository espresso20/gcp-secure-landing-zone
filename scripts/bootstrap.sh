#!/usr/bin/env bash
#
# One-time bootstrap.
#
#   scripts/bootstrap.sh          create folder, seed project and state bucket, then migrate
#   scripts/bootstrap.sh --migrate-only   just move stage 0's state into the bucket
#
# The awkward part of any Terraform foundation is that the stack which creates the state bucket
# has nowhere to keep its own state while it does so. The sequence is:
#
#   1. Apply stage 0 with local state. Folder, seed project and bucket now exist.
#   2. Write the resulting IDs into config.env, so nothing is transcribed by hand.
#   3. Add a backend block to stage 0 and `init -migrate-state` into the bucket it just made.
#
# After step 3 the local state file is redundant. It is left on disk rather than deleted,
# because deleting state automatically is not a habit worth building.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK_DIR="$REPO_ROOT/stacks/0-bootstrap"
CONFIG="$REPO_ROOT/config.env"
TF="${TF_BIN:-terraform}"

MIGRATE_ONLY=0
[[ "${1:-}" == "--migrate-only" ]] && MIGRATE_ONLY=1

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
die()  { printf '\n\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

[[ -f "$CONFIG" ]] || die "config.env not found. Run: make init-config"

# --- Apply -------------------------------------------------------------------------------------

if [[ $MIGRATE_ONLY -eq 0 ]]; then
  step "Stage 0 — folder, seed project, state bucket"
  echo "    This runs on LOCAL state. That is expected; step 3 moves it."
  "$REPO_ROOT/scripts/tf.sh" 0-bootstrap apply

  # --- Record ------------------------------------------------------------------------------------
  #
  # Read the values out of state rather than asking for them. A hand-copied project ID with a
  # transposed character fails several minutes into stage 1 with an unhelpful 403.

  step "Writing discovered IDs into config.env"

  SEED="$(cd "$STACK_DIR" && "$TF" output -raw seed_project)"
  BUCKET="$(cd "$STACK_DIR" && "$TF" output -raw state_bucket)"
  FOLDER="$(cd "$STACK_DIR" && "$TF" output -raw folder_id)"

  [[ -n "$SEED" && -n "$BUCKET" && -n "$FOLDER" ]] || die "stage 0 applied but did not produce outputs"

  cp "$CONFIG" "$CONFIG.bak"

  # Replace the key if present, append if not. Done with a temp file rather than sed -i so the
  # behaviour is the same on BSD and GNU.
  set_key() {
    local key="$1" val="$2" tmp
    tmp="$(mktemp)"
    if grep -q "^${key}=" "$CONFIG"; then
      while IFS= read -r line; do
        case "$line" in
          "${key}="*) printf '%s=%s\n' "$key" "$val" ;;
          *)          printf '%s\n' "$line" ;;
        esac
      done < "$CONFIG" > "$tmp"
    else
      cat "$CONFIG" > "$tmp"
      printf '%s=%s\n' "$key" "$val" >> "$tmp"
    fi
    mv "$tmp" "$CONFIG"
  }

  set_key GCP_SEED_PROJECT    "$SEED"
  set_key TF_VAR_state_bucket "$BUCKET"
  set_key TF_VAR_folder_id    "$FOLDER"

  ok "GCP_SEED_PROJECT=$SEED"
  ok "TF_VAR_state_bucket=$BUCKET"
  ok "TF_VAR_folder_id=$FOLDER"
  ok "previous config.env saved as config.env.bak"
fi

# --- Migrate -----------------------------------------------------------------------------------------

set -a
# shellcheck disable=SC1091
source "$CONFIG"
set +a

[[ -n "${TF_VAR_state_bucket:-}" ]] || die "TF_VAR_state_bucket is empty — nothing to migrate into"

step "Migrating stage 0 state into gs://$TF_VAR_state_bucket"

if grep -q 'backend "gcs"' "$STACK_DIR"/*.tf 2>/dev/null; then
  ok "backend block already present"
else
  cat > "$STACK_DIR/backend.tf" <<'BACKEND'
# Added by scripts/bootstrap.sh after the bucket below existed to receive it.
#
# Stage 0 ran on local state to create this bucket, then migrated into it. If you ever need to
# rebuild from nothing, delete this file, run stage 0 locally again, and re-migrate.
terraform {
  backend "gcs" {}
}
BACKEND
  ok "wrote stacks/0-bootstrap/backend.tf"
fi

( cd "$STACK_DIR" && "$TF" init -migrate-state -force-copy \
    -backend-config="bucket=$TF_VAR_state_bucket" \
    -backend-config="prefix=0-bootstrap" )

ok "state now lives in gs://$TF_VAR_state_bucket/0-bootstrap"

cat <<EOF

Bootstrap complete.

  Folder:  $TF_VAR_folder_id
  Seed:    ${GCP_SEED_PROJECT:-}
  State:   gs://$TF_VAR_state_bucket

The local state file at stacks/0-bootstrap/terraform.tfstate is now a backup copy.
It is gitignored. Delete it when you are satisfied the migration worked.

Next:  make up
EOF
