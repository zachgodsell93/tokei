.PHONY: build test check run app install clean

build:
	swift build

test:
	swift test

# Headless verification: fetches live usage from every connected provider.
check: build
	.build/debug/AIUsageMonitor --check

run: build
	.build/debug/AIUsageMonitor

app:
	bash scripts/build-app.sh

install: app
	rm -rf "/Applications/AI Usage Monitor.app"
	cp -R "build/AI Usage Monitor.app" /Applications/
	open "/Applications/AI Usage Monitor.app"

clean:
	rm -rf .build build
