APP_NAME      := AIPinyin
CONFIG        ?= release
BUILD_DIR     := build
APP           := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR   := $(HOME)/Library/Input Methods
INSTALLED_APP := $(INSTALL_DIR)/$(APP_NAME).app
# Any identity substring codesign accepts; falls back to ad-hoc signing if not found.
SIGN_IDENTITY ?= Apple Development

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

.PHONY: all deps build app settings-app test icon install uninstall cli status selftest screenshots realtest realtest-build realtest-run realtest-when-unlocked realtest-cancel clean distclean

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
	swift build -c $(CONFIG) --product $(APP_NAME)

app: build Resources/icon.tiff
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources" "$(APP)/Contents/Frameworks" "$(APP)/Contents/SharedSupport"
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp Resources/icon.tiff "$(APP)/Contents/Resources/icon.tiff"
	printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	cp $(RIME_LIB) "$(APP)/Contents/Frameworks/"
	cp -R $(RIME_DIST)/lib/rime-plugins "$(APP)/Contents/Frameworks/"
	cp -R $(RIME_DATA) "$(APP)/Contents/SharedSupport/rime"
	# Hardened runtime: library validation then only loads code signed by the same team, and
	# DYLD_* injection is ignored. Ad-hoc signing (no identity) can't use it.
	if security find-identity -v -p codesigning | grep -qF "$(SIGN_IDENTITY)"; then \
		codesign --force --options runtime --sign "$(SIGN_IDENTITY)" "$(APP)"/Contents/Frameworks/rime-plugins/*.dylib \
			"$(APP)/Contents/Frameworks/librime.1.dylib" && \
		codesign --force --options runtime --sign "$(SIGN_IDENTITY)" "$(APP)"; \
	else \
		echo "warning: no '$(SIGN_IDENTITY)' signing identity; ad-hoc signing without hardened runtime"; \
		codesign --force --sign - "$(APP)"/Contents/Frameworks/rime-plugins/*.dylib "$(APP)/Contents/Frameworks/librime.1.dylib" && \
		codesign --force --sign - "$(APP)"; \
	fi
	codesign --verify --strict --deep "$(APP)"
	@echo "Built $(APP)"

Resources/icon.tiff: Scripts/make-icon.swift
	swift Scripts/make-icon.swift $@

icon:
	swift Scripts/make-icon.swift Resources/icon.tiff

# 「AI 拼音设置」: launcher app for ~/Applications (Spotlight / Launchpad / Finder) that opens the
# input method's settings window. macOS shows no options for third-party input methods in System Settings.
SETTINGS_NAME := AI 拼音设置
SETTINGS_APP  := $(BUILD_DIR)/$(SETTINGS_NAME).app
USER_APPS     := $(HOME)/Applications

Resources/AppIcon.icns: Scripts/make-app-icon.swift
	swift Scripts/make-app-icon.swift $@

settings-app: Resources/AppIcon.icns
	swift build -c $(CONFIG) --product AIPinyinSettings
	rm -rf "$(SETTINGS_APP)"
	mkdir -p "$(SETTINGS_APP)/Contents/MacOS" "$(SETTINGS_APP)/Contents/Resources"
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/AIPinyinSettings" "$(SETTINGS_APP)/Contents/MacOS/AIPinyinSettings"
	cp Resources/Settings-Info.plist "$(SETTINGS_APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(SETTINGS_APP)/Contents/Resources/AppIcon.icns"
	printf 'APPL????' > "$(SETTINGS_APP)/Contents/PkgInfo"
	if security find-identity -v -p codesigning | grep -qF "$(SIGN_IDENTITY)"; then \
		codesign --force --options runtime --sign "$(SIGN_IDENTITY)" "$(SETTINGS_APP)"; \
	else \
		codesign --force --sign - "$(SETTINGS_APP)"; \
	fi
	codesign --verify --strict "$(SETTINGS_APP)"

test: deps
	swift test

# Stops the running IME (macOS relaunches it on next use), replaces the bundle, registers it.
# The bundle is moved, not copied: macOS launches input methods by bundle ID, and with a second
# copy left in build/ it may start that one instead of the installed one.
install: app settings-app
	@pkill -x $(APP_NAME) || true
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALLED_APP)"
	mv "$(APP)" "$(INSTALL_DIR)/"
	mkdir -p "$(USER_APPS)"
	rm -rf "$(USER_APPS)/$(SETTINGS_NAME).app"
	mv "$(SETTINGS_APP)" "$(USER_APPS)/"
	"$(INSTALLED_APP)/Contents/MacOS/$(APP_NAME)" --register

uninstall:
	-"$(INSTALLED_APP)/Contents/MacOS/$(APP_NAME)" --disable
	@pkill -x $(APP_NAME) || true
	rm -rf "$(INSTALLED_APP)" "$(USER_APPS)/$(SETTINGS_NAME).app"

status:
	"$(INSTALLED_APP)/Contents/MacOS/$(APP_NAME)" --status

# Drives the input controller (real Rime engine, live Bedrock call) with a fake text field.
OUT ?= /tmp/aipinyin-selftest
selftest: app
	"$(APP)/Contents/MacOS/$(APP_NAME)" --selftest "$(OUT)"

# README images, rendered by the self-test (needs a working Bedrock setup).
screenshots: selftest
	swift Scripts/make-readme-images.swift "$(OUT)" docs

# Types into a real NSTextView in a separate app through the *installed* input method and the
# system text input path (switches the input source for the test and restores it afterwards).
# Needs an unlocked screen; the harness window comes to the front for about a minute.
REALTEST     := $(BUILD_DIR)/RealTest.app
REALTEST_BIN := $(REALTEST)/Contents/MacOS/RealTest
TEST_LOGS    := $(HOME)/Library/Logs/AIPinyin
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
# persisted across logins; it removes itself when done). Log: ~/Library/Logs/AIPinyin/realtest-watch.log
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
	swift build -c $(CONFIG) --product aipinyin-cli
	@echo "Run: $$(swift build -c $(CONFIG) --show-bin-path)/aipinyin-cli <sentence>"

clean:
	rm -rf .build "$(BUILD_DIR)"

distclean: clean
	rm -rf $(DEPS)
