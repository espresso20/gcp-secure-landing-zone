# GCP study stack.
#
#   make help        what everything does
#   make up          foundation (cheap, leave running)
#   make lab-up      network + workload (costs money, tear down when done)
#   make lab-down    tear the expensive half back down
#
# Every target runs from the repo root. Nothing here requires you to cd into a stack.
#
# Written for GNU Make 3.81, which is what macOS ships. No .ONESHELL, no $(file), no
# .RECIPEPREFIX. If you are editing this on a machine with make 4.x, resist the upgrades.

SHELL := /bin/bash
.DEFAULT_GOAL := help

TF        ?= terraform
# 1-org is deliberately NOT in FOUNDATION. It writes at the organization node and only runs
# in an organization explicitly unlocked via ORG_WRITES_ALLOWED_FOR. `make up` must never
# reach it by accident.
STACKS    := 0-bootstrap 1-foundation 2-projects 3-network 4-workload 1-org
FOUNDATION := 1-foundation 2-projects
LAB       := 3-network 4-workload

# Ordered destroy: reverse of apply, or dependencies break.
LAB_DOWN  := 4-workload 3-network

C_BOLD := \033[1m
C_DIM  := \033[2m
C_GRN  := \033[32m
C_YEL  := \033[33m
C_RED  := \033[31m
C_OFF  := \033[0m

.PHONY: help stacks init-config ids auth auth-check preflight bootstrap bootstrap-migrate \
        up down lab-up lab-down plan apply destroy output fmt fmt-check validate lint \
        guard-test cost nuke clean docs status org-up org-down org-check \
        $(foreach s,$(STACKS),plan-$(s) apply-$(s) destroy-$(s) output-$(s) init-$(s))

## ---------------------------------------------------------------------------
## Help
## ---------------------------------------------------------------------------

help:
	@printf "$(C_BOLD)GCP study stack$(C_OFF)\n\n"
	@printf "$(C_BOLD)Getting started$(C_OFF)\n"
	@printf "  make init-config      create config.env from the example\n"
	@printf "  make ids              look up your org ID and billing account\n"
	@printf "  make auth             sign in (gcloud + ADC) and check access\n"
	@printf "  make preflight        verify everything before the first apply\n"
	@printf "  make bootstrap        stage 0: folder, seed project, state bucket\n"
	@printf "\n$(C_BOLD)Day to day$(C_OFF)\n"
	@printf "  make up               apply the foundation (org policy, audit, projects)\n"
	@printf "  make lab-up           apply network + workload   $(C_YEL)costs ~\$$35/mo while up$(C_OFF)\n"
	@printf "  make lab-down         destroy network + workload $(C_GRN)back to ~\$$1/mo$(C_OFF)\n"
	@printf "  make status           what exists right now\n"
	@printf "\n$(C_BOLD)Per stack$(C_OFF)  (STACK=one of: $(STACKS))\n"
	@printf "  make plan STACK=3-network\n"
	@printf "  make apply STACK=3-network\n"
	@printf "  make destroy STACK=3-network\n"
	@printf "  make output STACK=3-network\n"
	@printf "  $(C_DIM)shortcuts: make plan-3-network, make apply-3-network, ...$(C_OFF)\n"
	@printf "\n$(C_BOLD)Quality$(C_OFF)\n"
	@printf "  make fmt              terraform fmt -recursive\n"
	@printf "  make validate         validate every stack\n"
	@printf "  make lint             fmt-check + validate + shellcheck if present\n"
	@printf "  make guard-test       prove the blast-radius guard still blocks org writes\n"
	@printf "\n$(C_BOLD)Teardown$(C_OFF)\n"
	@printf "  make down             destroy everything except stage 0\n"
	@printf "  make nuke             $(C_RED)down + stage 0$(C_OFF) (state bucket and folder are protected)\n"
	@printf "  make clean            remove local .terraform dirs and plan files\n"
	@printf "\n"

stacks:
	@printf "%s\n" $(STACKS)

## ---------------------------------------------------------------------------
## Setup
## ---------------------------------------------------------------------------

init-config:
	@if [ -f config.env ]; then \
	  printf "$(C_YEL)config.env already exists, not overwriting$(C_OFF)\n"; \
	else \
	  cp config.env.example config.env; \
	  printf "$(C_GRN)created config.env$(C_OFF). Fill it in, then: make ids\n"; \
	fi

ids:
	@printf "$(C_BOLD)Organizations$(C_OFF)\n"
	@gcloud organizations list 2>/dev/null || printf "  (not authorized, run: make auth)\n"
	@printf "\n$(C_BOLD)Billing accounts$(C_OFF)\n"
	@gcloud billing accounts list 2>/dev/null || printf "  (not authorized, run: make auth)\n"
	@printf "\n$(C_BOLD)Cloud Identity customer ID$(C_OFF)  (for domain-restricted sharing)\n"
	@gcloud organizations list --format="value(owner.directoryCustomerId)" 2>/dev/null | sed 's/^/  /' || true
	@printf "\nPut these in config.env as TF_VAR_org_id, TF_VAR_billing_account, TF_VAR_customer_id\n"

auth:
	@scripts/auth.sh

auth-check:
	@scripts/auth.sh --check

preflight:
	@scripts/preflight.sh

bootstrap: preflight
	@scripts/bootstrap.sh

bootstrap-migrate:
	@scripts/bootstrap.sh --migrate-only

## ---------------------------------------------------------------------------
## Grouped lifecycle
## ---------------------------------------------------------------------------

up:
	@for s in $(FOUNDATION); do scripts/tf.sh $$s apply || exit 1; done
	@printf "\n$(C_GRN)Foundation up.$(C_OFF)  Idle cost is under \$$1/month.\n"
	@printf "Next: make lab-up  (brings up the network, the part that costs money)\n"

lab-up:
	@for s in $(LAB); do scripts/tf.sh $$s apply || exit 1; done
	@printf "\n$(C_GRN)Lab up.$(C_OFF)\n"
	@scripts/tf.sh 4-workload output ssh_command 2>/dev/null || true
	@printf "\n$(C_YEL)Roughly \$$35/month while this is running. 'make lab-down' when you stop.$(C_OFF)\n"

lab-down:
	@for s in $(LAB_DOWN); do scripts/tf.sh $$s destroy || exit 1; done
	@printf "\n$(C_GRN)Lab down.$(C_OFF) Foundation still up. KMS keys remain; GCP cannot delete them.\n"

down: lab-down
	@scripts/tf.sh 2-projects destroy
	@scripts/tf.sh 1-foundation destroy
	@printf "\n$(C_GRN)Everything below stage 0 is gone.$(C_OFF)\n"
	@printf "Stage 0 (folder, seed project, state bucket) is still there. 'make nuke' for that.\n"

nuke:
	@printf "$(C_RED)This destroys the whole playground, including the state bucket's project.$(C_OFF)\n"
	@printf "The folder and the state bucket have prevent_destroy set and will refuse.\n"
	@printf "Type the word 'nuke' to continue: "
	@read -r ans; [ "$$ans" = "nuke" ] || { printf "aborted\n"; exit 1; }
	@$(MAKE) down
	@scripts/tf.sh 0-bootstrap destroy

## ---------------------------------------------------------------------------
## Organization level
## ---------------------------------------------------------------------------
##
## Refuses unless config.env sets ORG_WRITES_ALLOWED_FOR to the same org as TF_VAR_org_id.
## scripts/tf.sh enforces that before init; the guard enforces it on the plan; the stack's own
## check block enforces it inside Terraform. Three places, set two different ways.

org-check:
	@if [ -f config.env ]; then \
	  . ./config.env; \
	  if [ -n "$$ORG_WRITES_ALLOWED_FOR" ]; then \
	    printf "$(C_YEL)org-node writes UNLOCKED for organization %s$(C_OFF)\n" "$$ORG_WRITES_ALLOWED_FOR"; \
	    printf "config.env TF_VAR_org_id is %s\n" "$$TF_VAR_org_id"; \
	    [ "$$ORG_WRITES_ALLOWED_FOR" = "$$TF_VAR_org_id" ] \
	      && printf "$(C_GRN)they match$(C_OFF)\n" \
	      || printf "$(C_RED)MISMATCH, every org target will refuse$(C_OFF)\n"; \
	  else \
	    printf "$(C_GRN)org-node writes blocked$(C_OFF) (folder-scoped mode)\n"; \
	  fi; \
	else printf "no config.env, run: make init-config\n"; fi

org-up:
	@printf "$(C_RED)stacks/1-org writes organization policy.$(C_OFF)\n"
	@printf "Every folder in the target organization will inherit it, including any you did not build.\n"
	@printf "Type the organization's numeric ID to continue: "
	@read -r ans; . ./config.env; [ "$$ans" = "$$ORG_WRITES_ALLOWED_FOR" ] || { printf "$(C_RED)that is not the unlocked org id, aborted$(C_OFF)\n"; exit 1; }
	@scripts/tf.sh 1-org apply

org-down:
	@scripts/tf.sh 1-org destroy

## ---------------------------------------------------------------------------
## Per-stack
## ---------------------------------------------------------------------------

plan:
	@test -n "$(STACK)" || { printf "$(C_RED)set STACK=$(C_OFF) one of: $(STACKS)\n"; exit 2; }
	@scripts/tf.sh $(STACK) plan

apply:
	@test -n "$(STACK)" || { printf "$(C_RED)set STACK=$(C_OFF) one of: $(STACKS)\n"; exit 2; }
	@scripts/tf.sh $(STACK) apply

destroy:
	@test -n "$(STACK)" || { printf "$(C_RED)set STACK=$(C_OFF) one of: $(STACKS)\n"; exit 2; }
	@scripts/tf.sh $(STACK) destroy

output:
	@test -n "$(STACK)" || { printf "$(C_RED)set STACK=$(C_OFF) one of: $(STACKS)\n"; exit 2; }
	@scripts/tf.sh $(STACK) output

status:
	@for s in $(STACKS); do \
	  printf "\n$(C_BOLD)%s$(C_OFF)\n" "$$s"; \
	  scripts/tf.sh $$s output 2>/dev/null | sed 's/^/  /' || printf "  (no state)\n"; \
	done

# Per-stack shortcuts, generated rather than written out five times. `make apply-3-network`
# is the same thing as `make apply STACK=3-network`, and is what you will actually type.
define STACK_TARGETS
plan-$(1):
	@scripts/tf.sh $(1) plan
apply-$(1):
	@scripts/tf.sh $(1) apply
destroy-$(1):
	@scripts/tf.sh $(1) destroy
output-$(1):
	@scripts/tf.sh $(1) output
init-$(1):
	@scripts/tf.sh $(1) reinit
endef

$(foreach s,$(STACKS),$(eval $(call STACK_TARGETS,$(s))))

## ---------------------------------------------------------------------------
## Quality
## ---------------------------------------------------------------------------

fmt:
	@$(TF) fmt -recursive .

fmt-check:
	@$(TF) fmt -check -recursive . || { printf "$(C_RED)unformatted, run: make fmt$(C_OFF)\n"; exit 1; }

validate:
	@for s in $(STACKS); do scripts/tf.sh $$s validate || exit 1; done

lint: fmt-check validate
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck scripts/*.sh && printf "$(C_GRN)shellcheck clean$(C_OFF)\n"; \
	else \
	  printf "$(C_DIM)shellcheck not installed, skipping$(C_OFF)\n"; \
	fi

guard-test:
	@scripts/guard-test.sh

cost:
	@printf "$(C_BOLD)Standing cost$(C_OFF)\n"
	@printf "  1-foundation   ~\$$0.50/mo   log storage, asset feed, Pub/Sub. Leave it up.\n"
	@printf "  2-projects     \$$0          projects are free; only contents bill.\n"
	@printf "  3-network      ~\$$33/mo     Cloud NAT gateway \$$32 + flow logs + DNS zones.\n"
	@printf "  4-workload     ~\$$2/mo      e2-micro (free tier eligible) + 10GB disk + KMS.\n"
	@printf "\n  Foundation only:  under \$$1/mo\n"
	@printf "  Everything up:    around \$$35/mo\n"
	@printf "\n$(C_DIM)Set enable_nat=false in stacks/3-network to drop the largest item,\n"
	@printf "at the cost of no outbound internet from private instances.$(C_OFF)\n"

docs:
	@if command -v terraform-docs >/dev/null 2>&1; then \
	  for m in modules/*/; do terraform-docs markdown table --output-file README.md "$$m"; done; \
	  printf "$(C_GRN)module READMEs regenerated$(C_OFF)\n"; \
	else \
	  printf "terraform-docs not installed: brew install terraform-docs\n"; \
	fi

clean:
	@find . -type d -name .terraform -prune -exec rm -rf {} + 2>/dev/null || true
	@find . -type f -name tfplan -delete 2>/dev/null || true
	@printf "$(C_GRN)local terraform artifacts removed$(C_OFF) (state in GCS is untouched)\n"
