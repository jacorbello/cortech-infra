SHELL := /bin/bash

.PHONY: inventory
inventory:
	@echo "Refreshing inventory and diagram..."
	scripts/inventory/refresh.sh
	@echo "Done. See docs/inventory.md and docs/diagram.md"

