# PRHub's make targets: the ones docs/workflow.md lists, and no others. Each CI workflow runs the target of its name.
#
#   make fix FILES="<files>"      each lint tool's own fixes on those files (the pre-commit hook passes the staged ones)
#   make lint-ios                 SwiftFormat, SwiftLint with the DESIGN.md token rules, the design-token check,
#                                 shellcheck, gitleaks
#   make lint-prkit               SwiftFormat, SwiftLint with the DESIGN.md token rules, gitleaks
#   make lint-worker              oxfmt, oxlint, tsc, shellcheck, gitleaks (needs `npm ci` in worker/ and agent/)
#   make lint-workflows           actionlint
#   make build-ios                compiles the app for the iOS Simulator and the Mac (lint-ios.yml's build job)
#   make test-unit-ios            swift test on PRHubUnitTests
#   make test-integration-ios     swift test on PRHubIntegrationTests: app persistence and Keychain
#   make test-ui-ios              the app-hosted rendering plan, then the UI plan, on one Simulator (SIMULATOR or SIM_NAME)
#   make test-unit-prkit          swift test on PRKitUnitTests
#   make test-integration-prkit   swift test on PRKitIntegrationTests: persistence, contracts, fonts, AppKit rendering
#   make test-ui-prkit            PRKit rendering, then native interactions, on one Simulator (SIMULATOR or SIM_NAME)
#   make test-unit-worker         Worker and agent unit tests (needs `npm ci` in worker/ and agent/)
#   make test-integration-worker  Worker storage and workerd tests, agent tests with real git and a local server
#   make lint                     all lint targets
#   make all-tests                all test targets
#
# Tools: mise (https://mise.jdx.dev) installs each pinned tool on first use. GNU Make 3.81 (macOS's): no .ONESHELL.

SHELL := /bin/bash
.PHONY: fix lint-ios lint-prkit lint-worker lint-workflows build-ios test-unit-ios test-integration-ios test-ui-ios \
	test-unit-prkit test-integration-prkit test-ui-prkit test-unit-worker test-integration-worker lint all-tests

X := mise exec
ACTIONLINT  := $(X) actionlint@1.7.12 -- actionlint
SHELLCHECK  := $(X) shellcheck@0.11.0 -- shellcheck
GITLEAKS    := $(X) gitleaks@8.30.1 -- gitleaks dir --config .gitleaks.toml --no-banner --redact
SWIFTFORMAT := $(X) swiftformat@0.64.7 -- swiftformat
SWIFTLINT   := $(X) swiftlint@0.65.1 -- swiftlint
XCODEGEN    := $(X) xcodegen@2.46.0 -- xcodegen
OXFMT       := npx --yes oxfmt@0.78.0
# worker/ has oxlint and its type-aware plugin as dev dependencies; agent/ has no dev dependencies, so it gets the same
# version from npx.
OXLINT_WORKER := npx --no-install oxlint
OXLINT        := npx --yes oxlint@1.93.0

# ---- Fix ------------------------------------------------------------------------------------------------------------

SWIFT_FILES := $(filter %.swift,$(FILES))
JS_FILES    := $(filter worker/% agent/%,$(filter %.ts %.tsx %.mts %.cts %.js %.mjs %.cjs,$(FILES)))

fix:
	$(if $(SWIFT_FILES),$(SWIFTFORMAT) --quiet $(SWIFT_FILES))
	$(if $(SWIFT_FILES),$(SWIFTLINT) --fix --quiet $(SWIFT_FILES))
	$(if $(JS_FILES),$(OXFMT) $(JS_FILES))
	$(if $(JS_FILES),$(OXLINT) --fix $(JS_FILES))
	$(if $(filter DESIGN.md,$(FILES)),$(MAKE) -C app design)

# ---- Lint -----------------------------------------------------------------------------------------------------------

lint-ios:
	$(SWIFTFORMAT) app --lint
	$(SWIFTLINT) lint --strict --quiet app/PRHub app/PRHubCore app/PRHubTests app/PRHubUITests app/PRHubRenderingTests \
		app/PRHubE2ETests app/PRHubPerformanceTests
	$(MAKE) -C app design-check
	$(SHELLCHECK) app/ci_scripts/ci_post_clone.sh
	$(GITLEAKS) app
	$(GITLEAKS) DESIGN.md

lint-prkit:
	$(SWIFTFORMAT) PRKit Package.swift --lint
	$(SWIFTLINT) lint --strict --quiet PRKit
	$(GITLEAKS) PRKit

lint-worker:
	$(OXFMT) --check worker agent
	cd worker && $(OXLINT_WORKER) --deny-warnings
	cd worker && $(OXLINT_WORKER) --type-aware --type-check --deny-warnings src
	npm --prefix worker run typecheck:test
	cd agent && $(OXLINT) --deny-warnings
	$(SHELLCHECK) scripts/ask-trace.sh
	$(GITLEAKS) worker
	$(GITLEAKS) agent
	$(GITLEAKS) deploy/hosted

lint-workflows:
	$(ACTIONLINT)

lint: lint-ios lint-prkit lint-worker lint-workflows

# ---- The Xcode project ----------------------------------------------------------------------------------------------
# app/PRHub.xcodeproj is generated from app/project.yml and gitignored. app/Package.resolved, the app's package pins,
# goes where Xcode reads them, as Xcode Cloud's app/ci_scripts/ci_post_clone.sh does. Without it, Xcode writes the
# app's pins (PostHog too) into the root Package.resolved, which belongs to `swift test` on Package.swift.

XCODE_PINS := app/PRHub.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
GENERATE_XCODE_PROJECT := $(XCODEGEN) generate --spec app/project.yml --quiet && mkdir -p $(XCODE_PINS) \
	&& cp app/Package.resolved $(XCODE_PINS)/Package.resolved
JOBS ?= 2
XCODEBUILD := cd app && xcodebuild -project PRHub.xcodeproj -scheme PRHub -derivedDataPath build/DerivedData -jobs $(JOBS)

build-ios:
	$(GENERATE_XCODE_PROJECT)
	$(XCODEBUILD) build -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
	$(XCODEBUILD) build -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO

# ---- Tests ----------------------------------------------------------------------------------------------------------

SWIFT_JOBS ?= 4

test-unit-ios:
	swift test -j $(SWIFT_JOBS) --filter PRHubUnitTests

test-integration-ios:
	swift test -j $(SWIFT_JOBS) --filter PRHubIntegrationTests

test-unit-prkit:
	swift test -j $(SWIFT_JOBS) --filter PRKitUnitTests

test-integration-prkit:
	swift test -j $(SWIFT_JOBS) --filter PRKitIntegrationTests

test-unit-worker:
	npm --prefix worker run test:unit
	npm --prefix agent run test:unit

test-integration-worker:
	npm --prefix worker run test:integration
	npm --prefix agent run test:integration

# The Simulator: SIMULATOR=<udid> (CI creates one a job), or else the one named SIM_NAME.
SIM_NAME ?= iPhone 17
SIMULATOR ?=
COMMA := ,
SIM_DESTINATION = $(if $(SIMULATOR),id=$(SIMULATOR),platform=iOS Simulator$(COMMA)name=$(SIM_NAME))
# One test plan on that Simulator; its result bundle is app/build/results/<plan>.xcresult.
XCODEBUILD_TEST = rm -rf app/build/results/$(1).xcresult && $(XCODEBUILD) test -testPlan $(1) \
	-destination '$(SIM_DESTINATION)' -resultBundlePath build/results/$(1).xcresult -parallel-testing-enabled NO

# The UI layer: rendering that needs the app host (serial, never retried), then the screens and interactions only a
# running app shows on the same owned Simulator; a test that fails runs once more.
test-ui-ios:
	$(GENERATE_XCODE_PROJECT)
	$(call XCODEBUILD_TEST,PRHubRenderingTests)
	$(call XCODEBUILD_TEST,PRHubUITests) -retry-tests-on-failure -test-iterations 2

# Library rendering and native interactions have their own full-target plans and do not rerun the app's UI tests.
test-ui-prkit:
	$(GENERATE_XCODE_PROJECT)
	$(call XCODEBUILD_TEST,PRKitRenderingTests)
	$(call XCODEBUILD_TEST,PRKitUITests) -retry-tests-on-failure -test-iterations 2

all-tests: test-unit-ios test-integration-ios test-ui-ios test-unit-prkit test-integration-prkit test-ui-prkit test-unit-worker \
	test-integration-worker
