# Clack — build/run wrapper around xcodebuild. Mirrors sidekick-ios so the
# muscle memory carries across our apps.
#
#   make run     — build + launch in the simulator
#   make device  — build + install + launch on a paired iPhone
#
# NOTE: PushToTalk needs the entitlement and a physical device — `make run`
# builds and launches in the sim, but the PTT system UI only works via
# `make device`.
#
APP_NAME       := Clack
SCHEME         := Clack
BUNDLE_ID      := ltd.anti.clack

PROJECT        := Clack.xcodeproj
BUILD_DIR      := build
DERIVED        := $(BUILD_DIR)/DerivedData
CONFIG         ?= Debug

# Simulator selection. Override on the command line:
#   make run SIM_NAME="iPhone 16 Pro Max"
SIM_NAME       ?= iPhone 17 Pro
SIM_DEST       := "platform=iOS Simulator,name=$(SIM_NAME)"

# Device selection. If exactly one iPhone is paired we use it automatically;
# pass DEVICE=<udid> or DEVICE_NAME="My iPhone" to force a specific one.
DEVICE         ?=
DEVICE_NAME    ?=

.PHONY: all project icon build run sim install clean stop help test \
        device device-install device-launch build-device

all: build

help:
	@echo "Simulator targets:"
	@echo "  make project — regenerate $(PROJECT) from project.yml (needs xcodegen)"
	@echo "  make icon    — render the app icon PNGs into Assets.xcassets"
	@echo "  make build   — xcodebuild for the iOS simulator"
	@echo "  make run     — boot the sim, install, launch"
	@echo "  make stop    — terminate the running sim instance"
	@echo "  make test    — run unit tests on the simulator"
	@echo "  make clean   — remove $(BUILD_DIR) and $(PROJECT)"
	@echo ""
	@echo "Device targets (requires a paired, unlocked iPhone):"
	@echo "  make device         — build + install + launch on the paired iPhone"
	@echo "  make device-install — build + install (no launch)"
	@echo "  make device-launch  — just relaunch the installed app"
	@echo ""
	@echo "Overrides:"
	@echo "  SIM_NAME=\"iPhone 16 Pro Max\"  pick a different simulator"
	@echo "  DEVICE=<udid>              pick a specific iPhone by UDID"
	@echo "  DEVICE_NAME=\"My iPhone\"     pick a specific iPhone by name"

# Render the app icon into Resources/Assets.xcassets via the standalone
# CoreGraphics script. Re-run whenever the brand mark changes.
icon:
	swift Tools/RenderAppIcon.swift

# Regenerate the xcodeproj from project.yml. XcodeGen is the source of truth.
project:
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "xcodegen not found. Install with: brew install xcodegen" >&2; exit 1; \
	}
	xcodegen generate
	@echo "Generated $(PROJECT)"

# Build for the iOS simulator. Generates the project on first run.
build: $(PROJECT)
	@mkdir -p $(BUILD_DIR)
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-destination $(SIM_DEST) \
		-derivedDataPath $(DERIVED) \
		build | xcbeautify --quiet 2>/dev/null || \
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-destination $(SIM_DEST) \
		-derivedDataPath $(DERIVED) \
		build

test: $(PROJECT)
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination $(SIM_DEST) \
		-derivedDataPath $(DERIVED) \
		test

# Boot the named simulator, install the freshly-built .app, launch it.
run: build
	@xcrun simctl boot "$(SIM_NAME)" 2>/dev/null || true
	@open -a Simulator
	@APP=$$(find $(DERIVED)/Build/Products -name "$(APP_NAME).app" -type d | head -n1); \
	if [ -z "$$APP" ]; then echo "No built .app found"; exit 1; fi; \
	xcrun simctl install "$(SIM_NAME)" "$$APP"; \
	xcrun simctl launch "$(SIM_NAME)" $(BUNDLE_ID)

stop:
	@xcrun simctl terminate "$(SIM_NAME)" $(BUNDLE_ID) 2>/dev/null || true

clean:
	rm -rf $(BUILD_DIR) $(PROJECT)

# ============================================================
# Device deployment — wraps `xcrun devicectl`. The device must already be
# paired with this Mac (plug in once, accept "Trust", unlock).
# ============================================================
DEVICE_UDID = $(shell \
	if [ -n "$(DEVICE)" ]; then \
		echo "$(DEVICE)"; \
	else \
		xcrun devicectl list devices 2>/dev/null \
			| awk -v name="$(DEVICE_NAME)" '\
				/^----/ {next} \
				name != "" && index($$0, name) == 0 {next} \
				{ \
					if (match($$0, /[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/)) { \
						print substr($$0, RSTART, RLENGTH); exit \
					} \
				}'; \
	fi)

build-device: $(PROJECT)
	@mkdir -p $(BUILD_DIR)
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-destination 'generic/platform=iOS' \
		-derivedDataPath $(DERIVED) \
		-allowProvisioningUpdates \
		build | xcbeautify --quiet 2>/dev/null || \
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-destination 'generic/platform=iOS' \
		-derivedDataPath $(DERIVED) \
		-allowProvisioningUpdates \
		build

device: device-install device-launch

device-install: build-device
	@if [ -z "$(DEVICE_UDID)" ]; then \
		echo ""; \
		echo "No paired iPhone found. Steps:" >&2; \
		echo "  1. Plug your phone in (or pair over Wi-Fi via Finder)." >&2; \
		echo "  2. Unlock it and accept the 'Trust This Computer' prompt." >&2; \
		echo "  3. Run: xcrun devicectl list devices" >&2; \
		echo "     If it lists the phone, re-run \`make device\`." >&2; \
		echo ""; \
		exit 1; \
	fi
	@APP=$$(find $(DERIVED)/Build/Products/Debug-iphoneos -name "$(APP_NAME).app" -type d | head -n1); \
	if [ -z "$$APP" ]; then echo "No iOS-device .app found in $(DERIVED)"; exit 1; fi; \
	echo "Installing $$APP to device $(DEVICE_UDID)..."; \
	xcrun devicectl device install app --device "$(DEVICE_UDID)" "$$APP"

device-launch:
	@if [ -z "$(DEVICE_UDID)" ]; then echo "No paired iPhone — see \`make device-install\`."; exit 1; fi
	@echo "Launching $(BUNDLE_ID) on $(DEVICE_UDID)..."
	xcrun devicectl device process launch --device "$(DEVICE_UDID)" "$(BUNDLE_ID)" || true
