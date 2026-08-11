.PHONY: bundle test

ifeq ($(OS),Windows_NT)
PYTHON ?= python
else
PYTHON ?= python3
endif

bundle:
	$(PYTHON) tools/build_offline_bundle.py

test:
	$(PYTHON) tools/check.py
