SHELL := /usr/bin/env bash
VENV := .venv-dev
BIN := $(VENV)/bin
BATS := tests/bats/bats-core/bin/bats
SH_PATHS := $(wildcard install.sh lib modules tools tests/stubs tests/test_helper.bash tests/integration)
PY_PATHS := $(wildcard helpers tests/python)

.PHONY: dev-deps lint pii test-bats test-py test-gjs test test-integration test-container

CONTAINER := $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)
IMAGE := tokyonight-ubuntu-test

dev-deps:
	python3 -m venv $(VENV)
	$(BIN)/pip install -q shellcheck-py==0.11.0.1 shfmt-py==4.2.0 ruff==0.17.3 # version, not an address: pii-scan: allow

lint:
	@if [ -n "$(SH_PATHS)" ]; then \
	  files=$$(find $(SH_PATHS) -type f \( -name '*.sh' -o -name '*.bash' -o -path 'tests/stubs/bin/*' -o -name install.sh \)); \
	  $(BIN)/shellcheck -S style $$files && $(BIN)/shfmt -i 2 -ci -d $$files; \
	fi
	@if [ -n "$(PY_PATHS)" ]; then $(BIN)/ruff check $(PY_PATHS); fi

pii:
	@python3 -I helpers/pii_scan.py $$([ -f .pii-denylist ] && echo "--denylist .pii-denylist") .

test-bats:
	@$(BATS) tests/bats/*.bats

test-py:
	@if [ -d tests/python ]; then python3 -I -m unittest discover -s tests/python; else echo "test-py: no tests/python yet"; fi

test-gjs:
	@if command -v gjs >/dev/null 2>&1; then gjs -m tests/gjs/theme-sync.test.js; \
	else echo "test-gjs: skipped (gjs not installed)"; fi

test: lint pii test-py test-bats test-gjs

# Real install.sh + real dconf in a temp HOME on a private D-Bus (never the session's).
test-integration:
	@tests/integration/run.sh

# The same in an Ubuntu 26.04 container, then with --system (root parts via sudo).
test-container:
	@if [ -z "$(CONTAINER)" ]; then echo "test-container: skipped (neither podman nor docker found)"; exit 0; fi; \
	$(CONTAINER) build -t $(IMAGE) -f tests/integration/Containerfile tests/integration && \
	$(CONTAINER) run --rm -v "$(CURDIR):/src:ro" -w /src --user tester -e TNU_IN_CONTAINER=1 $(IMAGE) \
	  bash -c 'tests/integration/run.sh && tests/integration/run.sh --system'
