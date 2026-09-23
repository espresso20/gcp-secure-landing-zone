#!/usr/bin/env bash
#
# Self-test for scripts/guard.sh.
#
#   scripts/guard-test.sh      (or: make guard-test)
#
# Runs guard.sh against fixtures representing the mistakes it exists to catch. Run it after
# touching guard.sh; preflight.sh also runs it before every bootstrap.
#
# The fixtures use a fake protected ID. Real ones live in config.env and are never committed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$(mktemp -d)"
trap 'rm -rf "$FIXTURES"' EXIT

# Not a real project ID.
FAKE_PROTECTED="protected-prod-example"

PASS=0
FAIL=0

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

#   expect_block <name> <json>   guard must REFUSE
#   expect_allow <name> <json>   guard must PERMIT
# Exported on every call, empty by default, so each fixture states the org-mode setting it is
# testing rather than inheriting config.env.
ORG_ALLOW=""

run_guard() {
  local json="$1"
  printf '%s' "$json" > "$FIXTURES/plan.json"
  PROTECTED_IDS="$FAKE_PROTECTED" ORG_WRITES_ALLOWED_FOR="$ORG_ALLOW" \
    "$REPO_ROOT/scripts/guard.sh" "$FIXTURES" "plan.json" >/dev/null 2>&1
}

expect_block() {
  local name="$1" json="$2"
  if run_guard "$json"; then
    fail "$name: guard ALLOWED this and should not have"
  else
    pass "$name"
  fi
}

expect_allow() {
  local name="$1" json="$2"
  if run_guard "$json"; then
    pass "$name"
  else
    fail "$name: guard BLOCKED this and should not have"
  fi
}

# Same two, with org mode enabled for one organization.
expect_block_in_org() {
  local name="$1" org="$2" json="$3"
  local prev="$ORG_ALLOW"; ORG_ALLOW="$org"
  expect_block "$name" "$json"
  ORG_ALLOW="$prev"
}

expect_allow_in_org() {
  local name="$1" org="$2" json="$3"
  local prev="$ORG_ALLOW"; ORG_ALLOW="$org"
  expect_allow "$name" "$json"
  ORG_ALLOW="$prev"
}

printf '\n\033[1mBlast-radius guard self-test\033[0m\n\n'

# Must be blocked

expect_block "org policy attached at the organization node" '{
  "resource_changes":[{"address":"google_org_policy_policy.oops","type":"google_org_policy_policy",
  "change":{"actions":["create"],"after":{"name":"organizations/123/policies/compute.vmExternalIpAccess","parent":"organizations/123"}}}]}'

expect_block "organization-wide log sink" '{
  "resource_changes":[{"address":"google_logging_organization_sink.all","type":"google_logging_organization_sink",
  "change":{"actions":["create"],"after":{"org_id":"123"}}}]}'

expect_block "IAM binding at the organization" '{
  "resource_changes":[{"address":"google_organization_iam_member.admin","type":"google_organization_iam_member",
  "change":{"actions":["create"],"after":{"org_id":"123","role":"roles/owner"}}}]}'

expect_block "custom constraint (org-only by definition)" '{
  "resource_changes":[{"address":"google_org_policy_custom_constraint.x","type":"google_org_policy_custom_constraint",
  "change":{"actions":["create"],"after":{"parent":"organizations/123"}}}]}'

expect_block "IAM binding on the protected project" '{
  "resource_changes":[{"address":"google_project_iam_member.x","type":"google_project_iam_member",
  "change":{"actions":["create"],"after":{"project":"protected-prod-example","role":"roles/owner"}}}]}'

expect_block "deleting a resource in the protected project" '{
  "resource_changes":[{"address":"google_storage_bucket.x","type":"google_storage_bucket",
  "change":{"actions":["delete"],"after":null,"before":{"project":"protected-prod-example"}},
  "change_after_note":"see below"}]}'

expect_block "essential contact attached at the organization" '{
  "resource_changes":[{"address":"google_essential_contacts_contact.x","type":"google_essential_contacts_contact",
  "change":{"actions":["create"],"after":{"parent":"organizations/123","email":"a@b.c"}}}]}'

expect_block "access context manager policy (org-scoped)" '{
  "resource_changes":[{"address":"google_access_context_manager_access_policy.x","type":"google_access_context_manager_access_policy",
  "change":{"actions":["create"],"after":{"parent":"organizations/123"}}}]}'

# Must be allowed. These matter as much as the blocks: a guard that refuses everything is
# indistinguishable from a broken repo, and the folder-creation case regressed once.

expect_allow "creating the playground folder under the org" '{
  "resource_changes":[{"address":"google_folder.playground","type":"google_folder",
  "change":{"actions":["create"],"after":{"display_name":"gcp-study-playground","parent":"organizations/123"}}}]}'

expect_allow "org policy attached at the folder" '{
  "resource_changes":[{"address":"google_org_policy_policy.ok","type":"google_org_policy_policy",
  "change":{"actions":["create"],"after":{"name":"folders/999/policies/compute.requireOsLogin","parent":"folders/999"}}}]}'

expect_allow "folder-scoped log sink" '{
  "resource_changes":[{"address":"google_logging_folder_sink.ok","type":"google_logging_folder_sink",
  "change":{"actions":["create"],"after":{"folder":"folders/999","include_children":true}}}]}'

expect_allow "hierarchical firewall policy on the folder" '{
  "resource_changes":[{"address":"google_compute_firewall_policy.ok","type":"google_compute_firewall_policy",
  "change":{"actions":["create"],"after":{"parent":"folders/999","short_name":"baseline"}}}]}'

expect_allow "a normal destroy of lab resources" '{
  "resource_changes":[
    {"address":"google_compute_instance.lab","type":"google_compute_instance",
     "change":{"actions":["delete"],"after":null,"before":{"project":"gcpstudy-dev-ab12"}}},
    {"address":"google_compute_router_nat.nat","type":"google_compute_router_nat",
     "change":{"actions":["delete"],"after":null,"before":{"project":"gcpstudy-net-ab12"}}}]}'

expect_allow "a read-only data source referencing the org" '{
  "resource_changes":[{"address":"data.google_organization.this","type":"google_organization",
  "change":{"actions":["read"],"after":{"org_id":"123"}}}]}'

expect_allow "an empty plan" '{"resource_changes":[]}'

# Organization mode. What matters here is not that org writes work, but that unlocking one
# organization does not unlock any other, and that anything ambiguous still fails closed.

LAB_ORG="111111111111"
OTHER_ORG="999999999999"

printf '\n\033[1morganization mode\033[0m  (ORG_WRITES_ALLOWED_FOR=%s)\n\n' "$LAB_ORG"

expect_allow_in_org "org policy at the allowed org" "$LAB_ORG" '{
  "resource_changes":[{"address":"google_org_policy_policy.at_lab","type":"google_org_policy_policy",
  "change":{"actions":["create"],"after":{"name":"organizations/111111111111/policies/compute.requireOsLogin","parent":"organizations/111111111111"}}}]}'

expect_allow_in_org "org log sink in the allowed org" "$LAB_ORG" '{
  "resource_changes":[{"address":"google_logging_organization_sink.all","type":"google_logging_organization_sink",
  "change":{"actions":["create"],"after":{"org_id":"111111111111"}}}]}'

expect_allow_in_org "custom constraint in the allowed org" "$LAB_ORG" '{
  "resource_changes":[{"address":"google_org_policy_custom_constraint.x","type":"google_org_policy_custom_constraint",
  "change":{"actions":["create"],"after":{"parent":"organizations/111111111111","name":"organizations/111111111111/customConstraints/custom.x"}}}]}'

# The one that matters most. Unlocking one org must not unlock any other.
expect_block_in_org "org policy aimed at a DIFFERENT org" "$LAB_ORG" '{
  "resource_changes":[{"address":"google_org_policy_policy.at_other","type":"google_org_policy_policy",
  "change":{"actions":["create"],"after":{"name":"organizations/999999999999/policies/compute.vmExternalIpAccess","parent":"organizations/999999999999"}}}]}'

expect_block_in_org "org log sink in a DIFFERENT org" "$LAB_ORG" '{
  "resource_changes":[{"address":"google_logging_organization_sink.other","type":"google_logging_organization_sink",
  "change":{"actions":["create"],"after":{"org_id":"999999999999"}}}]}'

# Ambiguity fails closed: an org-only resource type whose target org cannot be read.
expect_block_in_org "org-only resource with no determinable org" "$LAB_ORG" '{
  "resource_changes":[{"address":"google_organization_iam_member.mystery","type":"google_organization_iam_member",
  "change":{"actions":["create"],"after":{"role":"roles/owner","member":"user:a@b.c"}}}]}'

# Layer 2 is independent of layer 1. Org mode must not weaken the protected-ID check.
expect_block_in_org "protected project, while org mode is enabled" "$LAB_ORG" '{
  "resource_changes":[{"address":"google_project_iam_member.x","type":"google_project_iam_member",
  "change":{"actions":["create"],"after":{"project":"protected-prod-example","role":"roles/owner"}}}]}'

# Folder-scoped work keeps working unchanged in org mode.
expect_allow_in_org "folder-scoped policy, while org mode is enabled" "$LAB_ORG" '{
  "resource_changes":[{"address":"google_org_policy_policy.ok","type":"google_org_policy_policy",
  "change":{"actions":["create"],"after":{"name":"folders/999/policies/x","parent":"folders/999"}}}]}'

# Verdict

printf '\n'
if [[ $FAIL -eq 0 ]]; then
  printf '\033[32m%d/%d passed.\033[0m The guard blocks what it should and permits what it should.\n\n' "$PASS" "$((PASS+FAIL))"
  exit 0
fi

printf '\033[31m%d of %d FAILED.\033[0m Do not apply anything until scripts/guard.sh is fixed.\n\n' "$FAIL" "$((PASS+FAIL))"
exit 1
