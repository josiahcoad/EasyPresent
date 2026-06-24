PROJECT      = src/EasyPresent.xcodeproj
SCHEME       = EasyPresent
TEST_SCHEME  = EasyPresentTests
BUILD_DIR    = $(CURDIR)/build
APP_NAME     = EasyPresent
RELEASE_APP  = $(BUILD_DIR)/Build/Products/Release/$(APP_NAME).app
ENTITLEMENTS = $(CURDIR)/src/EasyPresent/Resources/EasyPresent-Release.entitlements
VERSION     ?= 0.0.0

# Stable self-signed code-signing identity. Unlike ad-hoc ("-"), a fixed cert keeps the
# same code "designated requirement" across rebuilds, so the macOS Accessibility grant
# (click-through / scroll-through) survives reinstalls and updates. Create it once via
# Keychain Access → Certificate Assistant → Create a Certificate (type: Code Signing),
# Common Name exactly "EasyPresent Self-Signed". Override with SIGN_IDENTITY=- for ad-hoc.
SIGN_IDENTITY ?= EasyPresent Self-Signed

# Load secrets from .env (if present)
-include .env
export

.PHONY: build test run dev release clean generate notarize dmg release-dmg

# Quick dev loop: build → install to /Applications → launch. Signs with the stable
# self-signed identity if present (so Accessibility persists), else falls back to ad-hoc.
dev:
	@IDENTITY="$(SIGN_IDENTITY)"; \
	if [ "$$IDENTITY" != "-" ] && ! security find-identity -p codesigning | grep -q "$$IDENTITY"; then \
		echo "⚠️  Code-signing identity '$$IDENTITY' not found — falling back to ad-hoc."; \
		echo "    Create it once: Keychain Access → Certificate Assistant → Create a Certificate"; \
		echo "    (type 'Code Signing', name 'EasyPresent Self-Signed'). Until then the"; \
		echo "    Accessibility grant resets on every rebuild."; \
		IDENTITY="-"; \
	fi; \
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(BUILD_DIR) \
		CODE_SIGN_IDENTITY="$$IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
		ENABLE_HARDENED_RUNTIME=NO build
	@osascript -e 'tell application "$(APP_NAME)" to quit' 2>/dev/null || true
	@pkill -9 -x $(APP_NAME) 2>/dev/null || true
	@while pgrep -x $(APP_NAME) >/dev/null 2>&1; do sleep 0.2; done  # ensure no stale instance lingers
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(BUILD_DIR)/Build/Products/Debug/$(APP_NAME).app /Applications/
	open /Applications/$(APP_NAME).app

# One command to ship an ad-hoc release: build DMG + GitHub release + bump Homebrew cask.
release-dmg:
	@test -n "$(VERSION)" || (echo "usage: make release-dmg VERSION=0.2.0" && exit 1)
	./scripts/release.sh $(VERSION)

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(BUILD_DIR) build

test:
	xcodebuild -project $(PROJECT) -scheme $(TEST_SCHEME) -configuration Debug -derivedDataPath $(BUILD_DIR) test

run: build
	open $(BUILD_DIR)/Build/Products/Debug/$(APP_NAME).app

release:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath $(BUILD_DIR) \
		CODE_SIGN_IDENTITY="Developer ID Application: $(DEVELOPER_NAME) ($(TEAM_ID))" \
		CODE_SIGN_STYLE=Manual \
		DEVELOPMENT_TEAM=$(TEAM_ID) \
		OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
		CODE_SIGN_ENTITLEMENTS=$(ENTITLEMENTS) \
		CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
		build

notarize: release
	@test -n "$(APPLE_ID)" || (echo "Error: APPLE_ID not set. Check .env file." && exit 1)
	@test -n "$(TEAM_ID)" || (echo "Error: TEAM_ID not set. Check .env file." && exit 1)
	@test -n "$(APP_PASSWORD)" || (echo "Error: APP_PASSWORD not set. Check .env file." && exit 1)
	@echo "--- Storing notarytool credentials ---"
	xcrun notarytool store-credentials "notarytool-profile" \
		--apple-id "$(APPLE_ID)" \
		--team-id "$(TEAM_ID)" \
		--password "$(APP_PASSWORD)"
	@echo "--- Creating ZIP for notarization ---"
	cd $(dir $(RELEASE_APP)) && ditto -c -k --keepParent $(APP_NAME).app $(APP_NAME)-notarize.zip
	@echo "--- Submitting for notarization (this may take several minutes) ---"
	xcrun notarytool submit $(dir $(RELEASE_APP))$(APP_NAME)-notarize.zip \
		--keychain-profile "notarytool-profile" --wait
	@echo "--- Stapling notarization ticket ---"
	xcrun stapler staple $(RELEASE_APP)
	@echo "--- Notarization complete ---"

dmg: notarize
	@echo "--- Creating DMG ---"
	rm -rf $(BUILD_DIR)/dmg-staging $(BUILD_DIR)/$(APP_NAME)-v$(VERSION).dmg
	mkdir -p $(BUILD_DIR)/dmg-staging
	cp -R $(RELEASE_APP) $(BUILD_DIR)/dmg-staging/
	ln -s /Applications $(BUILD_DIR)/dmg-staging/Applications
	hdiutil create \
		-volname "$(APP_NAME)" \
		-srcfolder $(BUILD_DIR)/dmg-staging \
		-ov -format UDZO \
		$(BUILD_DIR)/$(APP_NAME)-v$(VERSION).dmg
	rm -rf $(BUILD_DIR)/dmg-staging
	@echo "--- DMG created: $(BUILD_DIR)/$(APP_NAME)-v$(VERSION).dmg ---"

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(BUILD_DIR) clean
	rm -rf $(BUILD_DIR)

generate:
	cd src && xcodegen generate
