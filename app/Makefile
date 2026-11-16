# DESIGN.md's tokens: `make -C app design` writes app/PRHub's colour sets and PRKitDesign's DesignTokens.swift (commit
# what it writes); `design-check` changes nothing and fails when they are stale (the root Makefile's lint-ios).
.PHONY: design design-check

design:
	cd Tools/design && { [ -d node_modules ] || npm ci --silent; } && node generate.mjs

design-check:
	cd Tools/design && { [ -d node_modules ] || npm ci --silent; } && node generate.mjs --check
