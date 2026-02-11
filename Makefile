.PHONY: help packer-init build build-all molecule-gen publish publish-weekly cache-clean cache-clean-all cache-refresh cache-refresh-all

help:
	@echo "Targets:"
	@echo "  packer-init                 - packer init templates"
	@echo "  build BOX=<name>            - build one box (e.g. ubuntu-24.04, debian-12)"
	@echo "  build-all                   - build all boxes from packer/vars/*.pkrvars.hcl"
	@echo "  molecule-gen                - generate molecule/*-libvirt scenarios from packer/vars"
	@echo "  publish [BOX=<name>]        - publish one box (or see BOXES)"
	@echo "  publish BOXES=\"a b\"         - publish multiple boxes"
	@echo "  publish-weekly              - wrapper with locking/retries/logging"
	@echo "  cache-clean                 - clean build/download caches"
	@echo "  cache-clean-all             - clean all caches (sets CACHE_CLEAN_ALL=1)"
	@echo "  cache-refresh BOX=<name>    - wipe cache then rebuild one box"
	@echo "  cache-refresh-all           - wipe cache then rebuild all boxes"
	@echo "Variables:"
	@echo "  SHRINK=none|safe|full       - optional image shrinking mode (aliases: 0->none, 1->safe)"
	@echo "  PUBLISH_ARGS=\"...\"          - extra args for scripts/publish.sh (used by publish-weekly)"

packer-init:
	packer init packer/templates

build:
	@if [ -z "$(BOX)" ]; then echo "BOX is required"; exit 2; fi
	./scripts/build.sh "$(BOX)"

build-all:
	./scripts/build-all.sh

molecule-gen:
	./scripts/generate-molecule-scenarios.sh

publish:
	@# Optional: publish a single box via BOX=<name> or multiple via BOXES="a b"
	./scripts/publish.sh $(BOX) $(BOXES)

publish-weekly:
	./scripts/publish-weekly.sh

cache-clean:
	./scripts/cache-clean.sh

cache-clean-all:
	CACHE_CLEAN_ALL=1 ./scripts/cache-clean.sh

# Forces fresh downloads by wiping cache first, then rebuilding.
cache-refresh:
	@if [ -z "$(BOX)" ]; then echo "BOX is required (e.g. make cache-refresh BOX=ubuntu-24.04)"; exit 2; fi
	./scripts/cache-clean.sh
	./scripts/build.sh "$(BOX)"

cache-refresh-all:
	./scripts/cache-clean.sh
	./scripts/build-all.sh
