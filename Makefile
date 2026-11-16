# PRHub's make targets: the ones docs/workflow.md lists, and no others. Each CI workflow runs the target of its name.
#
#   make lint-ios                 SwiftFormat, SwiftLint with the DESIGN.md token rules, the design-token check, gitleaks
#   make lint-prkit               SwiftFormat, SwiftLint with the DESIGN.md token rules, gitleaks
#   make lint-worker              oxlint, oxfmt, tsc, gitleaks
#   make lint-workflows           actionlint
#   make test-unit-ios            swift test on the app packages (PRHubTests)
#   make test-unit-prkit          swift test on PRKit (PRKitTests)
#   make test-ui-ios              the UI test plan (SIM_NAME picks the Simulator: iPhone 17 by default)
#   make test-unit-worker         the Worker unit tests
#   make test-integration-worker  the agent/ tests
#   make lint                     all lint targets
#   make all-tests                all test targets
#
# Tools: mise (https://mise.jdx.dev) installs each pinned tool on first use. GNU Make 3.81 (macOS's): no .ONESHELL.

SHELL := /bin/bash
.PHONY: lint-ios lint-prkit lint-worker lint-workflows test-unit-ios test-unit-prkit test-ui-ios test-unit-worker \
	test-integration-worker lint all-tests

X := mise exec
ACTIONLINT  := $(X) actionlint@1.7.12 -- actionlint
GITLEAKS    := $(X) gitleaks@8.30.1 -- gitleaks dir --config .gitleaks.toml --no-banner --redact
SWIFTFORMAT := $(X) swiftformat@0.64.7 -- swiftformat
SWIFTLINT   := $(X) swiftlint@0.65.1 -- swiftlint lint --strict --quiet
XCODEGEN    := $(X) xcodegen@2.46.0 -- xcodegen
OXFMT       := npx --yes oxfmt@0.78.0
OXLINT      := npx --no-install oxlint

SIM_NAME ?= iPhone 17

lint-ios:
	$(SWIFTFORMAT) app --lint
	$(SWIFTLINT) app/PRHub app/PRHubTests app/PRHubUITests
	$(MAKE) -C app design-check
	zsh -n app/ci_scripts/ci_post_clone.sh
	$(GITLEAKS) app
	$(GITLEAKS) DESIGN.md

lint-prkit:
	$(SWIFTFORMAT) PRKit Package.swift --lint
	$(SWIFTLINT) PRKit
	$(GITLEAKS) PRKit

lint-worker:
	npm --prefix worker ci --no-audit --no-fund
	npm --prefix agent ci --no-audit --no-fund
	$(OXFMT) --check worker agent
	cd worker && $(OXLINT) --deny-warnings
	cd worker && $(OXLINT) --type-aware --type-check --deny-warnings src
	cd agent && npx --yes oxlint@1.93.0 --deny-warnings
	zsh -n scripts/ask-trace.sh
	$(GITLEAKS) worker
	$(GITLEAKS) agent
	$(GITLEAKS) deploy/hosted

lint-workflows:
	$(ACTIONLINT)

test-unit-ios:
	swift test --filter PRHubTests

test-unit-prkit:
	swift test --filter PRKitTests

# The samples flow and a picture of every screen, in app/build/screenshots.
test-ui-ios:
	cd app && $(XCODEGEN) generate --spec project.yml --quiet
	cd app && set -o pipefail && TEST_RUNNER_SCREENSHOTS_DIR=$(CURDIR)/app/build/screenshots xcodebuild test \
		-project PRHub.xcodeproj -scheme PRHub -testPlan PRHubUITests \
		-destination 'platform=iOS Simulator,name=$(SIM_NAME)' -derivedDataPath build/DerivedData

test-unit-worker:
	npm --prefix worker ci --no-audit --no-fund
	npm --prefix worker test

test-integration-worker:
	npm --prefix agent ci --no-audit --no-fund
	npm --prefix agent test

lint: lint-ios lint-prkit lint-worker lint-workflows

all-tests: test-unit-ios test-unit-prkit test-ui-ios test-unit-worker test-integration-worker
