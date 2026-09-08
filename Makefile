# `?=` so CI (and anyone with Xcode elsewhere) can override it:
# `make test DEVELOPER_DIR="$(xcode-select -p)"`. Unset, it is the local default.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

PROJECT := Codenotch.xcodeproj
SCHEME  := Codenotch
DEST    := platform=macOS,arch=arm64

.PHONY: gen build test run clean

gen:
	xcodegen generate

build: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Debug build

test: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Debug test

run: build
	@APP=$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $$2; exit}')/Codenotch.app; \
	pkill -x Codenotch || true; \
	open "$$APP"

# The `codenotch status` companion CLI. A plain tool target: ad-hoc signed
# like everything Debug, which is all a locally-run binary needs — Gatekeeper
# only cares about quarantined downloads, not things built on this machine.
cli: gen
	xcodebuild -project $(PROJECT) -target CodenotchCLI -destination '$(DEST)' \
		-configuration Debug build

# Installs the CLI onto PATH. PREFIX defaults to /usr/local (via `sudo`);
# Homebrew users will want `make install-cli PREFIX=/opt/homebrew`.
PREFIX ?= /usr/local
install-cli: cli
	@BIN=$$(xcodebuild -project $(PROJECT) -target CodenotchCLI -destination '$(DEST)' \
		-configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $$2; exit}')/codenotch; \
	install -d $(PREFIX)/bin; \
	install -m 755 "$$BIN" $(PREFIX)/bin/codenotch; \
	echo "Installed to $(PREFIX)/bin/codenotch"

clean:
	rm -rf build DerivedData $(PROJECT)

# --- Release -----------------------------------------------------------------
# The path to a notarized .dmg. Run `make release` for the whole thing, or the
# steps one at a time while something is going wrong.
#
# One-time setup, which you have to run yourself because it takes a password:
#
#   xcrun notarytool store-credentials Codenotch \
#       --apple-id <your-apple-id> --team-id <your-team-id> --password <app-specific-password>
#
# The app-specific password comes from appleid.apple.com → Sign-In and Security
# → App-Specific Passwords. Not your Apple ID password.

RELEASE_DIR := build/release
APP_NAME    := Codenotch
# The label of the stored notarytool credential in the login keychain.
# Created with the command above when there is a paid membership to notarize
# with; until then `make release` is maintainer-only and stays unused.
NOTARY_PROFILE := Codenotch
# The paid-membership Team ID `make release` signs and notarizes with. Empty
# until there is a membership to attach — set it on the command line or here
# when cutting a release becomes real: `make release TEAM_ID=XXXXXXXXXX`.
TEAM_ID ?= 
DMG := $(RELEASE_DIR)/$(APP_NAME).dmg

.PHONY: archive dmg notarize release verify-release

# Release configuration, exported with the Developer ID identity. `xcodebuild
# archive` + `-exportArchive` rather than a plain build: it re-signs the bundle
# as a distributable, which a Debug build is not.
archive: gen
	rm -rf $(RELEASE_DIR)
	mkdir -p $(RELEASE_DIR)
	@# Spotlight indexes build output as installed applications, so every
	@# release leaves extra "Codenotch" entries in app search next to the
	@# real one in /Applications. This stops the whole tree being indexed.
	@touch build/.metadata_never_index
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Release -archivePath $(RELEASE_DIR)/$(APP_NAME).xcarchive archive
	printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict>' \
		'<key>method</key><string>developer-id</string>' \
		'<key>teamID</key><string>$(TEAM_ID)</string>' \
		'<key>signingStyle</key><string>manual</string>' \
		'<key>signingCertificate</key><string>Developer ID Application</string>' \
		'</dict></plist>' > $(RELEASE_DIR)/ExportOptions.plist
	xcodebuild -exportArchive \
		-archivePath $(RELEASE_DIR)/$(APP_NAME).xcarchive \
		-exportOptionsPlist $(RELEASE_DIR)/ExportOptions.plist \
		-exportPath $(RELEASE_DIR)

# A plain drag-to-Applications disk image. `hdiutil` writes it read-only and
# compressed, which is what notarization expects.
dmg: archive
	rm -f $(DMG)
	rm -rf $(RELEASE_DIR)/stage
	mkdir -p $(RELEASE_DIR)/stage
	cp -R $(RELEASE_DIR)/$(APP_NAME).app $(RELEASE_DIR)/stage/
	ln -s /Applications $(RELEASE_DIR)/stage/Applications
	hdiutil create -volname "$(APP_NAME)" -srcfolder $(RELEASE_DIR)/stage \
		-ov -format UDZO $(DMG)
	codesign --force --sign "Developer ID Application" --timestamp $(DMG)
	@# The app is inside the dmg now. Leaving the loose copies around is how
	@# three spare "Codenotch" entries end up in Spotlight; everything
	@# downstream (notarize, verify, appcast) works from the dmg alone.
	rm -rf $(RELEASE_DIR)/stage $(RELEASE_DIR)/$(APP_NAME).app

# Submits and waits. `--wait` blocks until Apple answers, which is usually a
# couple of minutes; on rejection, the log says which binary failed and why.
notarize: dmg
	xcrun notarytool submit $(DMG) --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(DMG)

# Sparkle ships its tools inside the resolved package artifacts.
SPARKLE_BIN = $(shell dirname $$(find $$HOME/Library/Developer/Xcode/DerivedData/Codenotch-*/SourcePackages/artifacts/sparkle -name generate_appcast 2>/dev/null | head -1))

# The feed customers' copies poll. Signs each update with the EdDSA private key
# in the login keychain — Sparkle installs nothing that key did not sign, so a
# compromised host cannot push code.
#
# Writes into docs/, which GitHub Pages serves. The dmg goes there too, so the
# URL the appcast advertises is the one the file actually sits at — a mismatch
# is the usual reason an update downloads and then fails to verify.
# NOT docs/ — that holds the design frames and specs, and GitHub Pages serves
# whatever it is pointed at. Publishing from there would put the whole design
# history on the public web alongside the download.
PAGES_DIR := site
# Where the dmg actually sits. The enclosure URL the appcast advertises has to
# match it exactly, or an update downloads and then fails to verify.
DOWNLOAD_PREFIX := https://imrajyavardhan12.github.io/codenotch/

appcast: $(DMG)
	@test -n "$(SPARKLE_BIN)" || (echo "Sparkle tools not found — run make build first" && exit 1)
	mkdir -p $(PAGES_DIR)
	@# Rebuilt from what is actually in the folder, never merged into the old
	@# one. The dmg keeps a constant name, so only one build can exist at a
	@# time — but generate_appcast preserves entries it already knows, and left
	@# the previous version advertised at a URL now serving a different file,
	@# with a signature that could never verify.
	rm -f $(PAGES_DIR)/appcast.xml
	cp $(DMG) $(PAGES_DIR)/
	$(SPARKLE_BIN)/generate_appcast $(PAGES_DIR) --download-url-prefix $(DOWNLOAD_PREFIX)
	@echo "Publish by committing $(PAGES_DIR)/ and pushing."

release: notarize verify-release appcast
	@echo "Notarized: $(DMG)"

# What Gatekeeper on a customer's Mac will check. `spctl` accepting the app is
# the actual proof that the download will open without a right-click.
verify-release:
	xcrun stapler validate $(DMG)
	hdiutil attach $(DMG) -nobrowse -mountpoint $(RELEASE_DIR)/mnt
	codesign --verify --deep --strict --verbose=2 $(RELEASE_DIR)/mnt/$(APP_NAME).app
	spctl --assess --type execute --verbose=4 $(RELEASE_DIR)/mnt/$(APP_NAME).app
	hdiutil detach $(RELEASE_DIR)/mnt
