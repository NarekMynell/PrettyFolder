# PrettyFolder — build, test, install.
#
#   make install     build a release copy, put it in /Applications and start it
#   make test        run the unit tests
#   make run         build a debug copy and start it from the build folder
#   make uninstall   quit the app and remove it (see README for the folder icons)
#   make release     build a zip for GitHub Releases (notarized if NOTARY_PROFILE is set)
#   make readme-media  redraw the pictures and animations in docs/ (needs ffmpeg)

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

.PHONY: build debug test run install uninstall release readme-media icon clean

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
	-@pluginkit -r "$(abspath $(RELEASE_APP))/Contents/PlugIns/PrettyFolderFinder.appex" 2>/dev/null
	-@pluginkit -r "$(abspath $(DEBUG_APP))/Contents/PlugIns/PrettyFolderFinder.appex" 2>/dev/null
	pluginkit -a "$(INSTALL_DIR)/$(APP_NAME)/Contents/PlugIns/PrettyFolderFinder.appex"
	open "$(INSTALL_DIR)/$(APP_NAME)"
	@echo "Installed $(INSTALL_DIR)/$(APP_NAME)"

uninstall:
	-@killall PrettyFolder 2>/dev/null
	-pluginkit -e ignore -i $(EXTENSION_ID) 2>/dev/null
	-pluginkit -r "$(INSTALL_DIR)/$(APP_NAME)/Contents/PlugIns/PrettyFolderFinder.appex" 2>/dev/null
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	@echo "Removed. Your settings and stored pictures are in ~/Library/Application Support/PrettyFolder."

# Built apart from your own copies, ad-hoc signed unless DEVELOPER_ID is set, and kept
# out of Launch Services so Finder doesn't pick its extension up.
DIST_DERIVED := build/Dist
DIST_APP     := $(DIST_DERIVED)/Build/Products/Release/$(APP_NAME)
LSREGISTER   := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

release:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath $(DIST_DERIVED) \
		CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
	-@$(LSREGISTER) -u "$(abspath $(DIST_APP))" 2>/dev/null
	-@pluginkit -r "$(abspath $(DIST_APP))/Contents/PlugIns/PrettyFolderFinder.appex" 2>/dev/null
	./Scripts/package-release.sh "$(DIST_APP)" "$(DIST)"

# The animations are drawn by a debug build from the app's own views, off screen.
# The pictures on the folders are in docs/pictures.
readme-media: debug
	./Scripts/make-readme-media.sh "$(DEBUG_APP)" docs

icon:
	swift Scripts/make-app-icon.swift App/Assets.xcassets/AppIcon.appiconset

clean:
	rm -rf build $(DIST)
	cd Packages/PrettyFolderKit && swift package clean
