# PRHub — run from app/ (or `make -C app <target>`). Simulator builds need no secrets: the UI tests run on the samples.
SIM_NAME ?= iPhone 17
SIM_DESTINATION ?= platform=iOS Simulator,name=$(SIM_NAME)
DERIVED ?= build/DerivedData

.PHONY: project build test ui-test screenshots design design-check design-lint

project:
	xcodegen generate --spec project.yml --quiet

build: project
	xcodebuild build -project PRHub.xcodeproj -scheme PRHub -destination '$(SIM_DESTINATION)' \
		-derivedDataPath $(DERIVED) -quiet

# The app's unit tests and PRKit's.
test: project
	xcodebuild test -project PRHub.xcodeproj -scheme PRHub -destination '$(SIM_DESTINATION)' \
		-derivedDataPath $(DERIVED) -only-testing:PRHubTests -only-testing:PRKitTests

# The samples flow and every screen's pictures, into build/screenshots.
ui-test: project
	TEST_RUNNER_SCREENSHOTS_DIR=$(CURDIR)/build/screenshots xcodebuild test -project PRHub.xcodeproj -scheme PRHub \
		-destination '$(SIM_DESTINATION)' -derivedDataPath $(DERIVED) -only-testing:PRHubUITests

# DESIGN.md's tokens → app/PRHub's colour sets and PRKitDesign's DesignTokens.swift. Commit what it writes.
design:
	cd Tools/design && { [ -d node_modules ] || npm ci --silent; } && node generate.mjs

design-check:
	cd Tools/design && { [ -d node_modules ] || npm ci --silent; } && node generate.mjs --check

# No font size, colour, padding, corner or animation typed in a view (scripts/design-lint.sh).
design-lint:
	../scripts/design-lint.sh
