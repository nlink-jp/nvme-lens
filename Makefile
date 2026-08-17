APP_NAME   := NvmeLens
NAME       := nvme-lens
BUNDLE_ID  := jp.nlink.nvme-lens
VERSION    := $(shell git describe --tags --always --dirty 2>/dev/null || echo "0.1.0")
BUILD_DIR  := .build/release
DIST_DIR   := dist
APP_BUNDLE := $(DIST_DIR)/$(APP_NAME).app

CODESIGN_IDENTITY ?= Developer ID Application
NOTARY_PROFILE    ?= nlink-jp-notary
CODESIGN_SCRIPT   := scripts/codesign-darwin-app.sh
NOTARIZE_SCRIPT   := scripts/notarize-darwin-app.sh

.PHONY: build build-app package test fmt clean

build:
	@mkdir -p $(DIST_DIR)
	swift build -c release

build-app: build
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
# CFBundleShortVersionString has to be a dotted version, not a tag name and not
# a commit hash. The archive keeps the leading "v" (org convention); the plist
# drops it along with any -N-gSHA / -dirty suffix. An untagged build becomes
# 0.0.0 rather than showing a hash where the app prints its version.
	@plist_version=$$(printf '%s' '$(VERSION)' | sed -E 's/^v//; s/-.*$$//'); \
	 case "$$plist_version" in \
	   [0-9]*.[0-9]*) ;; \
	   *) plist_version=0.0.0 ;; \
	 esac; \
	 sed "s/\$${VERSION}/$$plist_version/g; s/\$${BUNDLE_ID}/$(BUNDLE_ID)/g; \
	      s/\$${APP_NAME}/$(APP_NAME)/g" Info.plist > $(APP_BUNDLE)/Contents/Info.plist
# icon.icns is a Phase 3 deliverable; the bundle assembles without it until then.
	@if [ -f icon.icns ]; then cp icon.icns $(APP_BUNDLE)/Contents/Resources/icon.icns; \
	 else echo "note: icon.icns not present yet, bundling without an icon"; fi
	@$(CODESIGN_SCRIPT) $(APP_BUNDLE) "$(CODESIGN_IDENTITY)"

package: build-app
	@$(NOTARIZE_SCRIPT) $(APP_BUNDLE) "$(NOTARY_PROFILE)"
	@cd $(DIST_DIR) && /usr/bin/ditto -c -k --keepParent \
		$(APP_NAME).app $(NAME)-$(VERSION)-darwin-arm64.zip

# Unit tests require no device and no smartmontools (ADR-0001 Decision 5).
test:
	swift test

fmt:
	swift format --in-place --recursive $(CURDIR)/Sources $(CURDIR)/Tests

clean:
	rm -rf $(DIST_DIR) .build
