# Entry point for deploying and removing inspection-agent stacks.
# Holds argument passing only. The logic lives in scripts/deploy.sh and scripts/teardown.sh.
# Compatible with GNU Make 3.81.

ENV ?= demo
REGION ?= us-west-2

DEPLOY := scripts/deploy.sh --env "$(ENV)" --region "$(REGION)"
TEARDOWN := scripts/teardown.sh --env "$(ENV)" --region "$(REGION)"
PACKAGE := scripts/package-agent.sh --env "$(ENV)" --region "$(REGION)"
TEMPLATES := $(wildcard infra/*.yaml infra/*.yml infra/*.json)

.DEFAULT_GOAL := help

.PHONY: help deploy teardown seed package lint

help:
	@echo "inspection-agent entry point"
	@echo ""
	@echo "Targets:"
	@echo "  make help                  Show this help (default)"
	@echo "  make deploy                Run the 10-step Deploy_Sequence"
	@echo "  make deploy-<component>    Create or update one stack"
	@echo "  make delete-<component>    Delete one stack"
	@echo "  make teardown              Delete all 8 stacks in Teardown_Sequence order"
	@echo "  make seed                  Load the schema and seed data into the database"
	@echo "  make package               Build and upload the agent code package"
	@echo "  make lint                  Run cfn-lint on infra/ templates, then ruff check"
	@echo ""
	@echo "First runtime deploy order: make deploy-runtime (Phase A), make package, make deploy-runtime (Phase B)"
	@echo ""
	@echo "Components: network auth database runtime memory observability ui mcp"
	@echo ""
	@echo "Inputs:"
	@echo "  ENV     Environment name, pattern ^[a-z][a-z0-9]{0,9}$$ (default: demo)"
	@echo "  REGION  AWS region (default: us-west-2)"
	@echo ""
	@echo "Example: make deploy ENV=dev1 REGION=us-west-2"

deploy:
	$(DEPLOY) deploy-all

deploy-%:
	$(DEPLOY) deploy "$*"

delete-%:
	$(DEPLOY) delete "$*"

teardown:
	$(TEARDOWN)

seed:
	scripts/seed.sh --env "$(ENV)" --region "$(REGION)"

package:
	$(PACKAGE)

lint:
ifneq ($(strip $(TEMPLATES)),)
	cfn-lint $(TEMPLATES)
endif
	ruff check .
