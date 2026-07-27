.PHONY: build test check run app dmg install clean

build:
	swift build

test:
	swift test

# Headless verification: fetches live usage from every connected provider.
check: build
	.build/debug/Tokei --check

run: build
	.build/debug/Tokei

app:
	bash scripts/build-app.sh

# Distributable disk image (build/Tokei-<version>.dmg)
dmg:
	bash scripts/build-dmg.sh

install: app
	rm -rf /Applications/Tokei.app
	cp -R build/Tokei.app /Applications/
	open /Applications/Tokei.app

clean:
	rm -rf .build build
