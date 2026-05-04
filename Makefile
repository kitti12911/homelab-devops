fmt:
	@echo "No Go formatter configured for this repository."

pretty:
	prettier --write "**/*.{md,markdown,yml,yaml,json,jsonc}"

format: fmt pretty
