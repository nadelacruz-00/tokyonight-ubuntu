SHELL := /usr/bin/env bash
VENV := .venv-dev
BIN := $(VENV)/bin
BATS := tests/bats/bats-core/bin/bats
SH_PATHS := $(wildcard install.sh lib modules tools tests/stubs tests/test_helper.bash)
PY_PATHS := $(wildcard helpers tests/python)

.PHONY: dev-deps lint pii test-bats test-py test test-integration test-container

dev-deps:
	python3 -m venv $(VENV)
	$(BIN)/pip install -q shellcheck-py shfmt-py ruff

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

test: lint pii test-py test-bats

test-integration:
	@if [ -d tests/integration ]; then $(BATS) -r tests/integration; else echo "test-integration: none yet"; fi

test-container:
	@if command -v podman >/dev/null 2>&1 || command -v docker >/dev/null 2>&1; then \
	  echo "test-container: not implemented yet"; \
	else echo "test-container: skipped (neither podman nor docker found)"; fi
