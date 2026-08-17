SHELL := /bin/bash

.PHONY: proxy-check
proxy-check:
	@echo "Comparing repo proxy config against LXC 100..."
	scripts/proxy-check.sh

.PHONY: inventory
inventory:
	@echo "Refreshing inventory and diagram..."
	scripts/inventory/refresh.sh
	@echo "Done. See docs/inventory.md and docs/diagram.md"

