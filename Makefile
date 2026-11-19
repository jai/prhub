# PRHub's make targets: the ones docs/workflow.md lists, and no others. Each CI workflow runs the target of its name.
#
#   make lint-ios                 SwiftFormat, SwiftLint with the DESIGN.md token rules, the design-token check,
#                                 shellcheck, gitleaks
#   make lint-prkit               SwiftFormat, SwiftLint with the DESIGN.md token rules, gitleaks
#   make lint-worker              oxlint, oxfmt, tsc, shellcheck, gitleaks
#   make lint-workflows           actionlint
#   make test-unit-ios            swift test on PRHubUnitTests
#   make test-unit-prkit          swift test on PRKitUnitTests
#   make test-ui-ios              the UI test plan (SIM_NAME picks the Simulator: iPhone 17 by default)
#   make test-unit-worker         Worker and agent unit tests
#   make test-integration-ios     app persistence and Keychain tests
#   make test-integration-prkit   PRKit persistence, contract and font tests
#   make test-integration-worker  Worker storage/runtime and agent integration tests
#   make lint                     all lint targets
#   make all-tests                all test targets
#
# Tools: mise (https://mise.jdx.dev) installs each pinned tool on first use. GNU Make 3.81 (macOS's): no .ONESHELL.

SHELL := /bin/bash
.PHONY: lint-ios lint-prkit lint-worker lint-workflows test-unit-ios test-unit-prkit test-ui-ios test-unit-worker \
	test-integration-worker test-integration-ios test-integration-prkit lint all-tests

X := mise exec
ACTIONLINT  := $(X) actionlint@1.7.12 -- actionlint
SHELLCHECK  := $(X) shellcheck@0.11.0 -- shellcheck
GITLEAKS    := $(X) gitleaks@8.30.1 -- gitleaks dir --config .gitleaks.toml --no-banner --redact
SWIFTFORMAT := $(X) swiftformat@0.64.7 -- swiftformat
SWIFTLINT   := $(X) swiftlint@0.65.1 -- swiftlint lint --strict --quiet
XCODEGEN    := $(X) xcodegen@2.46.0 -- xcodegen
OXFMT       := npx --yes oxfmt@0.78.0
OXLINT      := npx --no-install oxlint

SIM_NAME ?= iPhone 17
SIMULATOR ?=
COMMA := ,
UI_DESTINATION = $(if $(SIMULATOR),id=$(SIMULATOR),platform=iOS Simulator$(COMMA)name=$(SIM_NAME))

lint-ios:
	$(SWIFTFORMAT) app --lint
	$(SWIFTLINT) app/PRHub app/PRHubCore app/PRHubTests app/PRHubUITests app/PRHubRenderingTests app/PRHubE2ETests app/PRHubPerformanceTests
	$(MAKE) -C app design-check
	$(SHELLCHECK) app/ci_scripts/ci_post_clone.sh
	$(GITLEAKS) app
	$(GITLEAKS) DESIGN.md

lint-prkit:
	$(SWIFTFORMAT) PRKit Package.swift app/PRHubRenderingTests --lint
	$(SWIFTLINT) PRKit app/PRHubRenderingTests
	$(GITLEAKS) PRKit

lint-worker:
	$(OXFMT) --check worker agent
	cd worker && $(OXLINT) --deny-warnings
	cd worker && $(OXLINT) --type-aware --type-check --deny-warnings src
	npm --prefix worker run typecheck:test
	cd agent && npx --yes oxlint@1.93.0 --deny-warnings
	$(SHELLCHECK) scripts/ask-trace.sh
	$(GITLEAKS) worker
	$(GITLEAKS) agent
	$(GITLEAKS) deploy/hosted

lint-workflows:
	$(ACTIONLINT)

test-unit-ios:
	swift test -j 4 --filter PRHubUnitTests

test-unit-prkit:
	swift test -j 4 --filter PRKitUnitTests

test-integration-ios:
	swift test -j 4 --filter PRHubIntegrationTests

test-integration-prkit:
	swift test -j 4 --filter PRKitIntegrationTests

# The samples flow and a picture of every screen, in app/build/screenshots.
test-ui-ios:
	cd app && set -o pipefail && TEST_RUNNER_SCREENSHOTS_DIR=$(CURDIR)/app/build/screenshots xcodebuild test \
		-project PRHub.xcodeproj -scheme PRHub -testPlan PRHubUITests \
		-destination '$(UI_DESTINATION)' -derivedDataPath build/DerivedData \
		-retry-tests-on-failure -test-iterations 2 -jobs 4

test-unit-worker:
	npm --prefix worker run test:unit
	npm --prefix agent run test:unit

test-integration-worker:
	npm --prefix worker run test:integration
	npm --prefix agent run test:integration

lint: lint-ios lint-prkit lint-worker lint-workflows

all-tests: test-unit-ios test-integration-ios test-unit-prkit test-integration-prkit test-ui-ios test-unit-worker test-integration-worker
