# >>> repo header
# jai/prhub: the root Makefile (new). Built from jai/ci makefile.template; regenerate with jai/ci makefiles/sync.py.
#
# Languages: Swift (app/, PRKit/, Package.swift), TypeScript (worker/, relay/, e2e/), JavaScript (agent/), shell.
#
# The worker and relay type checks read src/, as tsc -p tsconfig.json did: the tests run on node --test. Type-aware
# rules that fire on today's code are off in worker/.oxlintrc.json until fixed. SwiftLint's limits are today's code.
# pyrefly needs uv: mise.toml pins it. app/Tools/design's JavaScript is not formatted or linted yet.
# app/Makefile stays as it is; `make -C app test` runs the app's tests on a Simulator, as the ios workflow does.
# <<< repo header
#
# Standard targets (jai/ci docs/make-targets.md):
#   make setup       tools, dependencies and git hooks; safe to run again
#   make fmt         format every file in place
#   make lint        format check and fast linters on all files; changes nothing (git pre-commit hook, CI Lint)
#   make typecheck   type checks and type-aware lint rules (CI Lint)
#   make test        unit tests: no network, no outside services (CI Unit Tests)
#   make check       lint, then typecheck and test for the parts that changed against origin/main (git pre-push hook)
#   make             same as make check
#
# Keep to GNU Make 3.81, the version macOS ships: no .ONESHELL, no .SHELLFLAGS, no $(file ...).
# A recipe line that fails stops the target. Put `set -o pipefail;` in front of any line with a pipe.
# Everything outside the two "repo" blocks comes from jai/ci makefile.template; change it there.

SHELL := /bin/bash
.DEFAULT_GOAL := check
.PHONY: setup fmt lint typecheck test check

# Tools. mise (https://mise.jdx.dev) installs each pinned tool on first use, so a target works in a fresh clone, a new
# worktree and a CI job alike. Runtimes (node, go, python) come from the repo's mise.toml or .tool-versions.
X := mise exec
RUN := $(X) --
# At most 4 parallel jobs on Jai's Macs (RULES.md): an uncapped hook held Cube 03 at 0% idle on 2026-11-16. Go tools
# (go test, go vet, golangci-lint) take GOMAXPROCS. Give a part's other runners $(JOBS): vitest and jest
# --maxWorkers=$(JOBS), xcodebuild -jobs $(JOBS), Gradle --max-workers=$(JOBS), golangci-lint --concurrency=$(JOBS).
JOBS := 4
export GOMAXPROCS := $(JOBS)
PREK        := $(X) prek@0.5.10 -- prek
ACTIONLINT  := $(X) actionlint@1.7.12 -- actionlint
GITLEAKS    := $(X) gitleaks@8.30.1 -- gitleaks
SHELLCHECK  := $(X) shellcheck@0.11.0 -- shellcheck
SHFMT       := $(X) shfmt@3.14.1 -- shfmt
# TypeScript and JavaScript. oxfmt needs no project setup, so it runs pinned from npm. oxlint, oxlint-tsgolint and
# typescript@7 are devDependencies of each package (lockfile-pinned): type-aware rules and --type-check need them there.
# OXLINT_NPX is for files outside any package.
OXFMT       := npx --yes oxfmt@0.78.0 --threads=$(JOBS)
OXLINT      := npx --no-install oxlint --threads=$(JOBS)
OXLINT_NPX  := npx --yes oxlint@1.93.0 --threads=$(JOBS)
# Python
RUFF        := $(X) ruff@0.17.5 -- ruff
# pipx: tools need uv on the machine: pin it in the repo's mise.toml or .tool-versions (uv 0.9 or later).
PYREFLY     := $(X) pipx:pyrefly@1.4.1 -- pyrefly
# Go. golangci-lint v2 also formats (`golangci-lint fmt`, formatters set in .golangci.yml).
GOLANGCI    := $(X) golangci-lint@2.15.0 -- golangci-lint
# Swift
SWIFTFORMAT := $(X) swiftformat@0.64.7 -- swiftformat
SWIFTLINT   := $(X) swiftlint@0.65.1 -- swiftlint
# PHP. Mago formats, lints and analyses in one binary.
MAGO        := $(X) mago@1.60.1 -- mago
# Terraform
TERRAFORM   := $(X) terraform@1.17.2 -- terraform
TFLINT      := $(X) tflint@0.66.0 -- tflint
# Security scanners, for the optional `security` target.
TRIVY       := $(X) trivy@0.76.2 -- trivy
OSV         := $(X) osv-scanner@2.3.8 -- osv-scanner
SEMGREP     := $(X) pipx:semgrep@1.151.0 -- semgrep

# Changed files, for `check`: committed since origin/main, uncommitted, and untracked.
# The default branch's tip, from origin/HEAD (master in ramen-beast-web); origin/main when origin/HEAD is not set.
BASE ?= $(or $(shell git rev-parse --abbrev-ref origin/HEAD 2>/dev/null),origin/main)
CHANGED := $(shell git diff --name-only $(BASE)...HEAD 2>/dev/null; git diff --name-only HEAD 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)
# A change to one of these runs every part.
EVERYTHING := Makefile mise.toml .tool-versions .pre-commit-config.yaml
# $(strip): Make 3.81 counts a blank $(if) condition as true, so with no part changed `make check` would loop.
changed_parts = $(strip $(if $(filter $(EVERYTHING),$(CHANGED)),$(PARTS),$(foreach p,$(PARTS),$(if $(filter $($(p)_PATHS),$(CHANGED)),$(p)))))

# Shell scripts by shebang. ShellCheck and shfmt read bash and sh; zsh scripts get `zsh -n`.
SH_FILES = $(shell git ls-files '*.sh' | xargs grep -l -E '^\#!.*(bash|/sh)' 2>/dev/null)
ZSH_FILES = $(shell git ls-files '*.sh' '*.zsh' | xargs grep -l -E '^\#!.*zsh' 2>/dev/null)

# >>> repo parts
PARTS := app worker relay agent e2e py

app_PATHS := app/% PRKit/% Package.swift Package.resolved .swiftformat .swiftlint.yml scripts/design-lint%
.PHONY: app-setup app-fmt app-lint app-typecheck app-test
app-setup:
	@:
app-fmt:
	$(SWIFTFORMAT) app PRKit Package.swift
app-lint:
	$(SWIFTFORMAT) app PRKit Package.swift --lint
	$(SWIFTLINT) lint --strict --quiet
	scripts/design-lint.sh
	scripts/scrub.sh
app-typecheck:
	swift build -j $(JOBS)
	$(MAKE) -C app design-check
app-test:
	swift test -j $(JOBS)

worker_PATHS := worker/% .oxfmtrc.json
.PHONY: worker-setup worker-fmt worker-lint worker-typecheck worker-test
worker-setup:
	npm --prefix worker ci --no-audit --no-fund
worker-fmt:
	$(OXFMT) worker
worker-lint:
	$(OXFMT) --check worker
	cd worker && $(OXLINT) --deny-warnings
worker-typecheck:
	cd worker && $(OXLINT) --type-aware --type-check --deny-warnings src
worker-test:
	npm --prefix worker test

relay_PATHS := relay/% .oxfmtrc.json
.PHONY: relay-setup relay-fmt relay-lint relay-typecheck relay-test
relay-setup:
	npm --prefix relay ci --no-audit --no-fund
relay-fmt:
	$(OXFMT) relay
relay-lint:
	$(OXFMT) --check relay
	cd relay && $(OXLINT) --deny-warnings
relay-typecheck:
	cd relay && $(OXLINT) --type-aware --type-check --deny-warnings src
relay-test:
	npm --prefix relay test

# agent/ is plain JavaScript (.mjs) with no TypeScript to check.
agent_PATHS := agent/% .oxfmtrc.json
.PHONY: agent-setup agent-fmt agent-lint agent-typecheck agent-test
agent-setup:
	npm --prefix agent ci --no-audit --no-fund
agent-fmt:
	$(OXFMT) agent
agent-lint:
	$(OXFMT) --check agent
	cd agent && $(OXLINT_NPX) --deny-warnings
agent-typecheck:
	@:
agent-test:
	npm --prefix agent test

# e2e/ drives the real app; its runs are UI tests, so `test` has nothing here.
e2e_PATHS := e2e/% .oxfmtrc.json
.PHONY: e2e-setup e2e-fmt e2e-lint e2e-typecheck e2e-test
e2e-setup:
	npm --prefix e2e ci --no-audit --no-fund
e2e-fmt:
	$(OXFMT) e2e
e2e-lint:
	$(OXFMT) --check e2e
	cd e2e && $(OXLINT) --deny-warnings
e2e-typecheck:
	cd e2e && $(OXLINT) --type-aware --type-check --deny-warnings
e2e-test:
	@:
# The Python scripts: the UI test slicer and the GitHub App setup.
PY_FILES := scripts/ui-test-slices.py deploy/github-app/create.py
py_PATHS := $(PY_FILES) ruff.toml
.PHONY: py-setup py-fmt py-lint py-typecheck py-test
py-setup:
	@:
py-fmt:
	$(RUFF) format $(PY_FILES)
py-lint:
	$(RUFF) format --check $(PY_FILES)
	$(RUFF) check $(PY_FILES)
py-typecheck:
	$(PYREFLY) check $(PY_FILES)
py-test:
	@:
# <<< repo parts

# Repo-wide: GitHub workflows, shell scripts, and secrets in the staged changes.
.PHONY: repo-fmt repo-lint
repo-fmt:
	$(if $(SH_FILES),$(SHFMT) -w $(SH_FILES),@:)
repo-lint:
	$(ACTIONLINT)
	$(if $(SH_FILES),$(SHFMT) -d $(SH_FILES),@:)
	$(if $(SH_FILES),$(SHELLCHECK) $(SH_FILES),@:)
	$(foreach f,$(ZSH_FILES),zsh -n $(f) &&) :
	$(GITLEAKS) git --pre-commit --staged --redact --no-banner

# mise reads the repo's mise.toml or .tool-versions only once the clone trusts it. CI sets
# MISE_TRUSTED_CONFIG_PATHS to the workspace instead.
.PHONY: mise-trust
mise-trust:
	mise trust --quiet
# The standard targets.
setup: mise-trust $(addsuffix -setup,$(PARTS))
	$(PREK) install --hook-type pre-commit --hook-type pre-push
fmt: repo-fmt $(addsuffix -fmt,$(PARTS))
lint: repo-lint $(addsuffix -lint,$(PARTS))
typecheck: $(addsuffix -typecheck,$(PARTS))
test: $(addsuffix -test,$(PARTS))
check: lint
	$(if $(changed_parts),$(MAKE) -f $(firstword $(MAKEFILE_LIST)) $(addsuffix -typecheck,$(changed_parts)) $(addsuffix -test,$(changed_parts)),@echo "check: no part changed against $(BASE)")
