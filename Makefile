# Define a directory for dependencies in the user's home folder
DEPS_DIR := $(HOME)/VoiceInk-Dependencies
WHISPER_CPP_DIR := $(DEPS_DIR)/whisper.cpp
FRAMEWORK_PATH := $(WHISPER_CPP_DIR)/build-apple/whisper.xcframework
LOCAL_DERIVED_DATA := $(CURDIR)/.local-build

.PHONY: all clean whisper setup build local local-incremental patch-fluidaudio check healthcheck help dev run

# Default target
all: check build

# Development workflow
dev: build run

# Prerequisites
check:
	@echo "Checking prerequisites..."
	@command -v git >/dev/null 2>&1 || { echo "git is not installed"; exit 1; }
	@command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild is not installed (need Xcode)"; exit 1; }
	@command -v swift >/dev/null 2>&1 || { echo "swift is not installed"; exit 1; }
	@echo "Prerequisites OK"

healthcheck: check

# Build process
whisper:
	@mkdir -p $(DEPS_DIR)
	@if [ ! -d "$(FRAMEWORK_PATH)" ]; then \
		echo "Building whisper.xcframework in $(DEPS_DIR)..."; \
		if [ ! -d "$(WHISPER_CPP_DIR)" ]; then \
			git clone https://github.com/ggerganov/whisper.cpp.git $(WHISPER_CPP_DIR); \
		else \
			(cd $(WHISPER_CPP_DIR) && git pull); \
		fi; \
		cd $(WHISPER_CPP_DIR) && ./build-xcframework.sh; \
	else \
		echo "whisper.xcframework already built in $(DEPS_DIR), skipping build"; \
	fi

setup: whisper
	@echo "Whisper framework is ready at $(FRAMEWORK_PATH)"
	@echo "Please ensure your Xcode project references the framework from this new location."

build: setup
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug CODE_SIGN_IDENTITY="" build

# Build for local use without Apple Developer certificate
local: check setup
	@echo "Building VoiceInk for local use (no Apple Developer certificate required)..."
	@rm -rf "$(LOCAL_DERIVED_DATA)"
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
		-derivedDataPath "$(LOCAL_DERIVED_DATA)" \
		-xcconfig LocalBuild.xcconfig \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=YES \
		DEVELOPMENT_TEAM="" \
		CODE_SIGN_ENTITLEMENTS="$(CURDIR)/VoiceInk/VoiceInk.local.entitlements" \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) LOCAL_BUILD' \
		build
	@APP_PATH="$(LOCAL_DERIVED_DATA)/Build/Products/Debug/VoiceInk.app" && \
	if [ -d "$$APP_PATH" ]; then \
		echo "Copying VoiceInk.app to ~/Downloads..."; \
		rm -rf "$$HOME/Downloads/VoiceInk.app"; \
		ditto "$$APP_PATH" "$$HOME/Downloads/VoiceInk.app"; \
		xattr -cr "$$HOME/Downloads/VoiceInk.app"; \
		echo ""; \
		echo "Build complete! App saved to: ~/Downloads/VoiceInk.app"; \
		echo "Run with: open ~/Downloads/VoiceInk.app"; \
		echo ""; \
		echo "Limitations of local builds:"; \
		echo "  - No iCloud dictionary sync"; \
		echo "  - No automatic updates (pull new code and rebuild to update)"; \
	else \
		echo "Error: Could not find built VoiceInk.app at $$APP_PATH"; \
		exit 1; \
	fi

FLUIDAUDIO_CHECKOUT := $(LOCAL_DERIVED_DATA)/SourcePackages/checkouts/FluidAudio

# Apply SSL-bypass patches to the SPM FluidAudio checkout (needed for MITM proxy support).
# Safe to run repeatedly — patches are idempotent.
patch-fluidaudio:
	@DOWNLOAD_UTILS="$(FLUIDAUDIO_CHECKOUT)/Sources/FluidAudio/DownloadUtils.swift"; \
	MODEL_REGISTRY="$(FLUIDAUDIO_CHECKOUT)/Sources/FluidAudio/ModelRegistry.swift"; \
	if [ ! -f "$$DOWNLOAD_UTILS" ]; then \
		echo "FluidAudio checkout not found at $(FLUIDAUDIO_CHECKOUT) — run 'make local' first to create it"; \
		exit 1; \
	fi; \
	echo "Patching FluidAudio for proxy/SSL support..."; \
	chmod u+w "$$DOWNLOAD_UTILS" "$$MODEL_REGISTRY"; \
	if grep -q "public static let sharedSession" "$$DOWNLOAD_UTILS"; then \
		sed -i '' 's/public static let sharedSession/nonisolated(unsafe) public static var sharedSession/' "$$DOWNLOAD_UTILS"; \
		echo "  DownloadUtils.swift: sharedSession let→var"; \
	else \
		echo "  DownloadUtils.swift: already patched"; \
	fi; \
	if grep -q "	static func configuredSession" "$$MODEL_REGISTRY"; then \
		sed -i '' 's/	static func configuredSession/	public static func configuredSession/' "$$MODEL_REGISTRY"; \
		PATCH_BODY="		if ProcessInfo.processInfo.environment[\"VOICEINK_IGNORE_SSL\"] == \"1\" {\n			return URLSession(configuration: configuration, delegate: SSLBypassDelegate(), delegateQueue: nil)\n		}"; \
		sed -i '' "s/		return URLSession(configuration: configuration)$$/$$PATCH_BODY\n		return URLSession(configuration: configuration)/" "$$MODEL_REGISTRY"; \
		printf '\n// MARK: - SSL Bypass Delegate\n\n/// URLSessionDelegate that bypasses TLS certificate validation.\n/// Only activated when VOICEINK_IGNORE_SSL env var is set to \"1\".\nprivate final class SSLBypassDelegate: NSObject, URLSessionDelegate {\n    func urlSession(\n        _ session: URLSession,\n        didReceive challenge: URLAuthenticationChallenge,\n        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void\n    ) {\n        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,\n            let serverTrust = challenge.protectionSpace.serverTrust\n        else {\n            completionHandler(.performDefaultHandling, nil)\n            return\n        }\n        completionHandler(.useCredential, URLCredential(trust: serverTrust))\n    }\n}\n' >> "$$MODEL_REGISTRY"; \
		echo "  ModelRegistry.swift: patched with SSLBypassDelegate"; \
	else \
		echo "  ModelRegistry.swift: already patched"; \
	fi; \
	if command -v swift-format >/dev/null 2>&1; then \
		swift-format --in-place --configuration "$(FLUIDAUDIO_CHECKOUT)/.swift-format" "$$DOWNLOAD_UTILS" "$$MODEL_REGISTRY" 2>/dev/null || true; \
	fi; \
	echo "FluidAudio patching done"

# Incremental build: re-uses existing .local-build (preserving SPM checkout) and applies
# FluidAudio proxy/SSL patches before compiling. Use after a full `make local` bootstrap.
local-incremental: check patch-fluidaudio
	@echo "Building VoiceInk (incremental, skipPackageUpdates)..."
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
		-derivedDataPath "$(LOCAL_DERIVED_DATA)" \
		-xcconfig LocalBuild.xcconfig \
		-skipPackageUpdates \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=YES \
		DEVELOPMENT_TEAM="" \
		CODE_SIGN_ENTITLEMENTS="$(CURDIR)/VoiceInk/VoiceInk.local.entitlements" \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) LOCAL_BUILD' \
		build
	@APP_PATH="$(LOCAL_DERIVED_DATA)/Build/Products/Debug/VoiceInk.app" && \
	if [ -d "$$APP_PATH" ]; then \
		echo "Copying VoiceInk.app to ~/Downloads..."; \
		rm -rf "$$HOME/Downloads/VoiceInk.app"; \
		ditto "$$APP_PATH" "$$HOME/Downloads/VoiceInk.app"; \
		xattr -cr "$$HOME/Downloads/VoiceInk.app"; \
		echo ""; \
		echo "Build complete! App saved to: ~/Downloads/VoiceInk.app"; \
		echo "Run with: open ~/Downloads/VoiceInk.app"; \
	else \
		echo "Error: Could not find built VoiceInk.app at $$APP_PATH"; \
		exit 1; \
	fi

# Run application
run:
	@if [ -d "$$HOME/Downloads/VoiceInk.app" ]; then \
		echo "Opening ~/Downloads/VoiceInk.app..."; \
		open "$$HOME/Downloads/VoiceInk.app"; \
	else \
		echo "Looking for VoiceInk.app in DerivedData..."; \
		APP_PATH=$$(find "$$HOME/Library/Developer/Xcode/DerivedData" -name "VoiceInk.app" -type d | head -1) && \
		if [ -n "$$APP_PATH" ]; then \
			echo "Found app at: $$APP_PATH"; \
			open "$$APP_PATH"; \
		else \
			echo "VoiceInk.app not found. Please run 'make build' or 'make local' first."; \
			exit 1; \
		fi; \
	fi

# Cleanup
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(DEPS_DIR)
	@echo "Clean complete"

# Help
help:
	@echo "Available targets:"
	@echo "  check/healthcheck  Check if required CLI tools are installed"
	@echo "  whisper            Clone and build whisper.cpp XCFramework"
	@echo "  setup              Copy whisper XCFramework to VoiceInk project"
	@echo "  build              Build the VoiceInk Xcode project"
	@echo "  local              Build for local use (no Apple Developer certificate needed)"
	@echo "  local-incremental  Incremental build with proxy/SSL patches (faster, no clean)"
	@echo "  patch-fluidaudio   Apply proxy/SSL patches to FluidAudio SPM checkout"
	@echo "  run                Launch the built VoiceInk app"
	@echo "  dev                Build and run the app (for development)"
	@echo "  all                Run full build process (default)"
	@echo "  clean              Remove build artifacts"
	@echo "  help               Show this help message"