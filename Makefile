.PHONY: bundle test

bundle:
	python3 tools/build_offline_bundle.py

test: bundle
	python3 tools/check.py
