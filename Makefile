# PrettyFolder — build, test, install.
#
#   make install     build a release copy, put it in /Applications and start it
#   make test        run the unit tests
#   make run         build a debug copy and start it from the build folder
#   make uninstall   quit the app and remove it (see README for the folder icons)
#   make release     build a zip for GitHub Releases (notarized if NOTARY_PROFILE is set)

PROJECT      := PrettyFolder.xcodeproj
SCHEME       := PrettyFolder
APP_NAME     := PrettyFolder.app
EXTENSION_ID := com.narekmynell.PrettyFolder.FinderExtension
DERIVED      := build/DerivedData
INSTALL_DIR  ?= /Applications
DIST         := dist

RELEASE_APP  := $(DERIVED)/Build/Products/Release/$(APP_NAME)
DEBUG_APP    := $(DERIVED)/Build/Products/Debug/$(APP_NAME)
VERSION       = $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$(RELEASE_APP)/Contents/Info.plist")

XCODEBUILD   := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED)

.PHONY: build debug test run install uninstall release icon clean

build:
	$(XCODEBUILD) -configuration Release build

debug:
	$(XCODEBUILD) -configuration Debug build

test:
	cd Packages/PrettyFolderKit && swift test

run: debug
	-@killall PrettyFolder 2>/dev/null; sleep 0.5
	open "$(DEBUG_APP)"

install: build
	-@killall PrettyFolder 2>/dev/null; sleep 0.5
	@# Finder starts the extension again on demand, from the new copy.
	-@killall PrettyFolderFinder 2>/dev/null
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	ditto "$(RELEASE_APP)" "$(INSTALL_DIR)/$(APP_NAME)"
	@# Make sure Finder loads the extension from the installed copy, not the build folder.
	-pluginkit -r "$(abspath $(RELEASE_APP))/Contents/PlugIns/PrettyFolderFinder.appex" 2>/dev/null
	-pluginkit -r "$(abspath $(DEBUG_APP))/Contents/PlugIns/PrettyFolderFinder.appex" 2>/dev/null
	pluginkit -a "$(INSTALL_DIR)/$(APP_NAME)/Contents/PlugIns/PrettyFolderFinder.appex"
	open "$(INSTALL_DIR)/$(APP_NAME)"
	@echo "Installed $(INSTALL_DIR)/$(APP_NAME)"

uninstall:
	-@killall PrettyFolder 2>/dev/null
	-pluginkit -e ignore -i $(EXTENSION_ID) 2>/dev/null
	-pluginkit -r "$(INSTALL_DIR)/$(APP_NAME)/Contents/PlugIns/PrettyFolderFinder.appex" 2>/dev/null
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	@echo "Removed. Your settings and stored pictures are in ~/Library/Application Support/PrettyFolder."

release: build
	./Scripts/package-release.sh "$(RELEASE_APP)" "$(DIST)"

icon:
	swift Scripts/make-app-icon.swift App/Assets.xcassets/AppIcon.appiconset

clean:
	rm -rf build $(DIST)
	cd Packages/PrettyFolderKit && swift package clean
