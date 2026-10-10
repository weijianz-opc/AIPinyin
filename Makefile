APP_NAME      := AllInOneIME
CONFIG        ?= release
BUILD_DIR     := build
APP           := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR   := $(HOME)/Library/Input Methods
INSTALLED_APP := $(INSTALL_DIR)/$(APP_NAME).app
# Any identity substring codesign accepts; falls back to ad-hoc signing if not found.
SIGN_IDENTITY ?= Apple Development
# Developer ID signatures get a secure timestamp (from Apple, over the network): notarization needs it.
# Goes by the certificate SIGN_IDENTITY picks, so a hash works too.
TIMESTAMP = $(shell security find-identity -v -p codesigning | grep -F -- '$(SIGN_IDENTITY)' | grep -q 'Developer ID' && echo --timestamp)
# Architectures to build for; empty: this Mac's. `make dmg` builds for both (DIST_ARCHS).
ARCHS ?=
SWIFT_BUILD = swift build -c $(CONFIG) $(foreach arch,$(ARCHS),--arch $(arch))

# Level one: official librime release build (BSD-3) and the rime-ice dictionaries (GPL-3.0).
LIBRIME_VERSION := 1.16.1
LIBRIME_TARBALL := rime-de4700e-macOS-universal.tar.bz2
LIBRIME_SHA256  := 147dc220d20bcf2650889c98f943f1792b3c675dbef91f42f9151a216ad2c372
RIME_ICE_TAG    := 2026.06.30
RIME_ICE_ZIP    := rime-ice-$(RIME_ICE_TAG)-full.zip
RIME_ICE_SHA256 := 675d23b070be00e1b800f9a6db033ef98f4493cd5b568ed8aa3b3541769c46ac

DEPS       := ThirdParty
RIME_DIST  := $(DEPS)/librime/dist
RIME_LIB   := $(RIME_DIST)/lib/librime.1.dylib
RIME_DATA  := $(DEPS)/rime-data
RIME_BUILT := $(RIME_DATA)/build/rime_ice.table.bin

.PHONY: all deps build app settings-app installer-app dmg test icon install uninstall cli status selftest screenshots realtest realtest-build realtest-run realtest-when-unlocked realtest-cancel clean distclean

all: app

deps: $(RIME_LIB) $(RIME_BUILT)

$(RIME_LIB):
	mkdir -p $(DEPS)
	[ -f $(DEPS)/$(LIBRIME_TARBALL) ] || curl -fsSL -o $(DEPS)/$(LIBRIME_TARBALL) \
		https://github.com/rime/librime/releases/download/$(LIBRIME_VERSION)/$(LIBRIME_TARBALL)
	echo "$(LIBRIME_SHA256)  $(DEPS)/$(LIBRIME_TARBALL)" | shasum -a 256 -c -
	rm -rf $(DEPS)/librime && mkdir -p $(DEPS)/librime
	tar xjf $(DEPS)/$(LIBRIME_TARBALL) -C $(DEPS)/librime
	touch $@

# Unpacks rime-ice and prebuilds its dictionaries, so deployment on the user's machine is quick.
$(RIME_BUILT): $(RIME_LIB) Resources/rime/default.custom.yaml
	[ -f $(DEPS)/$(RIME_ICE_ZIP) ] || curl -fsSL -o $(DEPS)/$(RIME_ICE_ZIP) \
		https://github.com/iDvel/rime-ice/releases/download/$(RIME_ICE_TAG)/full.zip
	echo "$(RIME_ICE_SHA256)  $(DEPS)/$(RIME_ICE_ZIP)" | shasum -a 256 -c -
	rm -rf $(RIME_DATA) && mkdir -p $(RIME_DATA)
	unzip -q $(DEPS)/$(RIME_ICE_ZIP) -d $(RIME_DATA)
	cp Resources/rime/default.custom.yaml $(RIME_DATA)/
	DYLD_LIBRARY_PATH="$(CURDIR)/$(RIME_DIST)/lib" $(RIME_DIST)/bin/rime_deployer --build \
		$(RIME_DATA) $(RIME_DATA) $(RIME_DATA)/build > $(DEPS)/rime-prebuild.log 2>&1
	rm -f $(RIME_DATA)/user.yaml $(RIME_DATA)/installation.yaml
	rm -rf $(RIME_DATA)/*.userdb
	test -f $@

build: deps
	$(SWIFT_BUILD) --product $(APP_NAME)

app: build Resources/icon.tiff Resources/AppIcon.icns
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources" "$(APP)/Contents/Frameworks" "$(APP)/Contents/SharedSupport"
	cp "$$($(SWIFT_BUILD) --show-bin-path)/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	Scripts/strip-rpaths.sh "$(APP)/Contents/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	# The licenses travel with the binaries (librime's BSD license asks for its notice).
	cp Resources/icon.tiff Resources/AppIcon.icns LICENSE THIRD_PARTY_NOTICES.md "$(APP)/Contents/Resources/"
	for lang in en zh-Hans; do \
		mkdir -p "$(APP)/Contents/Resources/$$lang.lproj" && \
		cp "Resources/$$lang.lproj/InfoPlist.strings" "$(APP)/Contents/Resources/$$lang.lproj/"; \
	done
	printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	cp $(RIME_LIB) "$(APP)/Contents/Frameworks/"
	cp -R $(RIME_DIST)/lib/rime-plugins "$(APP)/Contents/Frameworks/"
	cp -R $(RIME_DATA) "$(APP)/Contents/SharedSupport/rime"
	# Hardened runtime: library validation then only loads code signed by the same team, and
	# DYLD_* injection is ignored. Ad-hoc signing (no identity) can't use it. The entitlements
	# allow, under the hardened runtime, microphone access (voice input), Apple events to Notes
	# (@note) and Reminders (@reminder); the installer and `make dmg` ship this same build.
	if security find-identity -v -p codesigning | grep -qF "$(SIGN_IDENTITY)"; then \
		codesign --force --options runtime $(TIMESTAMP) --sign "$(SIGN_IDENTITY)" "$(APP)"/Contents/Frameworks/rime-plugins/*.dylib \
			"$(APP)/Contents/Frameworks/librime.1.dylib" && \
		codesign --force --options runtime $(TIMESTAMP) --entitlements Resources/AllInOneIME.entitlements \
			--sign "$(SIGN_IDENTITY)" "$(APP)"; \
	else \
		echo "warning: no '$(SIGN_IDENTITY)' signing identity; ad-hoc signing without hardened runtime"; \
		codesign --force --sign - "$(APP)"/Contents/Frameworks/rime-plugins/*.dylib "$(APP)/Contents/Frameworks/librime.1.dylib" && \
		codesign --force --sign - "$(APP)"; \
	fi
	codesign --verify --strict --deep "$(APP)"
	@echo "Built $(APP)"

# Both icons come from the 1024 px artwork Resources/AppIcon.png: the app icon (input method and
# settings launcher) and the menu-bar template icon.
Resources/icon.tiff: Scripts/make-icon.swift Resources/AppIcon.png
	swift Scripts/make-icon.swift Resources/AppIcon.png $@

Resources/AppIcon.icns: Scripts/make-app-icon.swift Resources/AppIcon.png
	swift Scripts/make-app-icon.swift Resources/AppIcon.png $@

icon:
	swift Scripts/make-icon.swift Resources/AppIcon.png Resources/icon.tiff
	swift Scripts/make-app-icon.swift Resources/AppIcon.png Resources/AppIcon.icns

# AllInOneIME Settings (「AllInOneIME 设置」): launcher app for ~/Applications (Spotlight / Launchpad /
# Finder) that opens the input method's settings window. macOS shows no options for third-party input
# methods in System Settings. Finder shows its name in the system language (Settings-*.lproj).
SETTINGS_NAME := AllInOneIME Settings
SETTINGS_APP  := $(BUILD_DIR)/$(SETTINGS_NAME).app
USER_APPS     := $(HOME)/Applications

# Installed under the old name (AIPinyin) by earlier versions; removed on install and uninstall.
LEGACY_APP_NAME      := AIPinyin
LEGACY_INSTALLED_APP := $(INSTALL_DIR)/$(LEGACY_APP_NAME).app
LEGACY_SETTINGS_APP  := $(USER_APPS)/AI 拼音设置.app
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

settings-app: Resources/AppIcon.icns
	$(SWIFT_BUILD) --product AllInOneIMESettings
	rm -rf "$(SETTINGS_APP)"
	mkdir -p "$(SETTINGS_APP)/Contents/MacOS" "$(SETTINGS_APP)/Contents/Resources"
	cp "$$($(SWIFT_BUILD) --show-bin-path)/AllInOneIMESettings" "$(SETTINGS_APP)/Contents/MacOS/AllInOneIMESettings"
	Scripts/strip-rpaths.sh "$(SETTINGS_APP)/Contents/MacOS/AllInOneIMESettings"
	cp Resources/Settings-Info.plist "$(SETTINGS_APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(SETTINGS_APP)/Contents/Resources/AppIcon.icns"
	for lang in en zh-Hans; do \
		mkdir -p "$(SETTINGS_APP)/Contents/Resources/$$lang.lproj" && \
		cp "Resources/Settings-$$lang.lproj/InfoPlist.strings" "$(SETTINGS_APP)/Contents/Resources/$$lang.lproj/"; \
	done
	printf 'APPL????' > "$(SETTINGS_APP)/Contents/PkgInfo"
	if security find-identity -v -p codesigning | grep -qF "$(SIGN_IDENTITY)"; then \
		codesign --force --options runtime $(TIMESTAMP) --sign "$(SIGN_IDENTITY)" "$(SETTINGS_APP)"; \
	else \
		codesign --force --sign - "$(SETTINGS_APP)"; \
	fi
	codesign --verify --strict "$(SETTINGS_APP)"

# 「安装 AllInOneIME」 (Install AllInOneIME): the installer on the release disk image. Both apps go in
# as one zip archive, which it unpacks into place like `make install` (Sources/AllInOneIMEInstaller).
# They are moved into the archive, not copied: build/ keeps no second AllInOneIME.app (same bundle
# ID) for macOS to launch instead of the installed one. Stored uncompressed: the disk image
# compresses it better. Without this Mac's extended attributes and ACLs.
INSTALLER_NAME := Install AllInOneIME
INSTALLER_APP  := $(BUILD_DIR)/$(INSTALLER_NAME).app
PAYLOAD_DIR    := $(BUILD_DIR)/payload

installer-app: app settings-app
	$(SWIFT_BUILD) --product AllInOneIMEInstaller
	rm -rf "$(INSTALLER_APP)" "$(PAYLOAD_DIR)"
	mkdir -p "$(INSTALLER_APP)/Contents/MacOS" "$(INSTALLER_APP)/Contents/Resources" "$(PAYLOAD_DIR)"
	cp "$$($(SWIFT_BUILD) --show-bin-path)/AllInOneIMEInstaller" "$(INSTALLER_APP)/Contents/MacOS/AllInOneIMEInstaller"
	Scripts/strip-rpaths.sh "$(INSTALLER_APP)/Contents/MacOS/AllInOneIMEInstaller"
	cp Resources/Installer-Info.plist "$(INSTALLER_APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(INSTALLER_APP)/Contents/Resources/AppIcon.icns"
	for lang in en zh-Hans; do \
		mkdir -p "$(INSTALLER_APP)/Contents/Resources/$$lang.lproj" && \
		cp "Resources/Installer-$$lang.lproj/InfoPlist.strings" "$(INSTALLER_APP)/Contents/Resources/$$lang.lproj/"; \
	done
	printf 'APPL????' > "$(INSTALLER_APP)/Contents/PkgInfo"
	mv "$(APP)" "$(SETTINGS_APP)" "$(PAYLOAD_DIR)/"
	ditto -c -k --norsrc --noextattr --noacl --zlibCompressionLevel 0 "$(PAYLOAD_DIR)" "$(INSTALLER_APP)/Contents/Resources/Payload.zip"
	rm -rf "$(PAYLOAD_DIR)"
	if security find-identity -v -p codesigning | grep -qF "$(SIGN_IDENTITY)"; then \
		codesign --force --options runtime $(TIMESTAMP) --sign "$(SIGN_IDENTITY)" "$(INSTALLER_APP)"; \
	else \
		codesign --force --sign - "$(INSTALLER_APP)"; \
	fi
	codesign --verify --strict "$(INSTALLER_APP)"
	@echo "Built $(INSTALLER_APP)"

# The release: build/AllInOneIME-<version>.dmg and its .sha256, with the installer (universal: Apple
# silicon and Intel), a read-me and the licenses (Scripts/make-dmg.sh). Signed with DIST_IDENTITY, a
# Developer ID Application certificate, if the keychain has one, else ad-hoc; then macOS asks users
# to allow the installer once (System Settings → Privacy & Security → Open Anyway). NOTARY_PROFILE,
# a keychain profile saved with `xcrun notarytool store-credentials`, also notarizes and staples it.
VERSION        := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
DMG            := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).dmg
DIST_IDENTITY  ?= Developer ID Application
DIST_ARCHS     ?= arm64 x86_64
NOTARY_PROFILE ?=

dmg:
	$(MAKE) installer-app SIGN_IDENTITY="$(DIST_IDENTITY)" ARCHS="$(DIST_ARCHS)"
	Scripts/make-dmg.sh "$(INSTALLER_APP)" "$(DMG)" "$(APP_NAME) $(VERSION)" "$(DIST_IDENTITY)" "$(NOTARY_PROFILE)"

test: deps
	swift test

# Stops the running IME (macOS relaunches it on next use), replaces the bundle, registers it
# (--register also keeps it in the user's input sources, so Ctrl+Space reaches it).
# The bundle is moved, not copied: macOS launches input methods by bundle ID, and with a second
# copy left in build/ it may start that one instead of the installed one. A copy installed under
# the old name (same bundle ID) is removed for the same reason; the new one takes over its data.
install: app settings-app
	@pkill -x $(APP_NAME) || true
	@pkill -x $(LEGACY_APP_NAME) || true
	mkdir -p "$(INSTALL_DIR)"
	-"$(LSREGISTER)" -u "$(LEGACY_INSTALLED_APP)" "$(LEGACY_SETTINGS_APP)" 2>/dev/null
	rm -rf "$(INSTALLED_APP)" "$(LEGACY_INSTALLED_APP)"
	mv "$(APP)" "$(INSTALL_DIR)/"
	mkdir -p "$(USER_APPS)"
	rm -rf "$(USER_APPS)/$(SETTINGS_NAME).app" "$(LEGACY_SETTINGS_APP)"
	mv "$(SETTINGS_APP)" "$(USER_APPS)/"
	"$(LSREGISTER)" -f "$(INSTALLED_APP)" "$(USER_APPS)/$(SETTINGS_NAME).app"
	"$(INSTALLED_APP)/Contents/MacOS/$(APP_NAME)" --register
	@pkill -x $(LEGACY_APP_NAME) || true

uninstall:
	-"$(INSTALLED_APP)/Contents/MacOS/$(APP_NAME)" --disable
	@pkill -x $(APP_NAME) || true
	@pkill -x $(LEGACY_APP_NAME) || true
	rm -rf "$(INSTALLED_APP)" "$(USER_APPS)/$(SETTINGS_NAME).app" "$(LEGACY_INSTALLED_APP)" "$(LEGACY_SETTINGS_APP)"

status:
	"$(INSTALLED_APP)/Contents/MacOS/$(APP_NAME)" --status

# Drives the input controller (real Rime engine, live Bedrock call) with a fake text field.
OUT ?= /tmp/allinoneime-selftest
selftest: app
	"$(APP)/Contents/MacOS/$(APP_NAME)" --selftest "$(OUT)"

# README images, rendered by the self-test (needs a working Bedrock setup): docs/ with the Chinese
# interface and captions, docs/en/ with the English ones (the same states, rendered in English).
screenshots: selftest
	swift Scripts/make-readme-images.swift "$(OUT)" docs
	swift Scripts/make-readme-images.swift "$(OUT)" docs/en en

# Types into a real NSTextView in a separate app through the *installed* input method and the
# system text input path (switches the input source for the test and restores it afterwards).
# Needs an unlocked screen; the harness window comes to the front for about a minute.
REALTEST     := $(BUILD_DIR)/RealTest.app
REALTEST_BIN := $(REALTEST)/Contents/MacOS/RealTest
TEST_LOGS    := $(HOME)/Library/Logs/AllInOneIME
REALTEST_OUT ?= $(TEST_LOGS)/realtest
realtest: realtest-build realtest-run

realtest-build:
	rm -rf "$(REALTEST)"
	mkdir -p "$(REALTEST)/Contents/MacOS"
	cp Scripts/RealTest-Info.plist "$(REALTEST)/Contents/Info.plist"
	swiftc -O -o "$(REALTEST_BIN)" Scripts/realapp-test.swift -framework AppKit -framework Carbon
	codesign --force --sign - "$(REALTEST)"

# Runs the already built harness; the input source is restored here too in case the test hung.
realtest-run:
	rm -rf "$(REALTEST_OUT)"
	mkdir -p "$(REALTEST_OUT)"
	open -W -n --stdout "$(REALTEST_OUT)/output.txt" --stderr "$(REALTEST_OUT)/stderr.txt" "$(REALTEST)" --args "$(REALTEST_OUT)"
	@"$(REALTEST_BIN)" --restore-input-source "$(REALTEST_OUT)"
	@cat "$(REALTEST_OUT)/output.txt"
	@grep -q '^REALTEST PASSED' "$(REALTEST_OUT)/output.txt"

# Runs the real-app test automatically once the screen is unlocked (temporary launchd job, not
# persisted across logins; it removes itself when done). Log: ~/Library/Logs/AllInOneIME/realtest-watch.log
WATCH_LABEL := com.aipinyin.realtest-watch
WATCH_PLIST := $(TEST_LOGS)/realtest-watch.plist
realtest-when-unlocked: realtest-build
	@launchctl bootout gui/$$(id -u)/$(WATCH_LABEL) 2>/dev/null || true
	mkdir -p "$(TEST_LOGS)"
	rm -f "$(WATCH_PLIST)"
	plutil -create xml1 "$(WATCH_PLIST)"
	plutil -insert Label -string $(WATCH_LABEL) "$(WATCH_PLIST)"
	plutil -insert ProgramArguments -array "$(WATCH_PLIST)"
	plutil -insert ProgramArguments -string /bin/sh -append "$(WATCH_PLIST)"
	plutil -insert ProgramArguments -string "$(CURDIR)/Scripts/realtest-when-unlocked.sh" -append "$(WATCH_PLIST)"
	plutil -insert ProcessType -string Interactive "$(WATCH_PLIST)"
	launchctl bootstrap gui/$$(id -u) "$(WATCH_PLIST)"
	launchctl kickstart gui/$$(id -u)/$(WATCH_LABEL)
	@echo "Scheduled: the real-app test runs once after the next unlock (cancel: make realtest-cancel)"

realtest-cancel:
	@launchctl bootout gui/$$(id -u)/$(WATCH_LABEL) 2>/dev/null || true
	rm -f "$(WATCH_PLIST)"

cli:
	swift build -c $(CONFIG) --product allinoneime-cli
	@echo "Run: $$(swift build -c $(CONFIG) --show-bin-path)/allinoneime-cli <sentence>"

clean:
	rm -rf .build "$(BUILD_DIR)"

distclean: clean
	rm -rf $(DEPS)
