# OpenTaskManager build entry points. Run `make help` for the list.

# Use full Xcode even when xcode-select points at the Command Line Tools,
# which lack xcodebuild and the Swift Testing runtime.
ifeq ($(origin DEVELOPER_DIR), undefined)
  ifneq ($(findstring CommandLineTools,$(shell xcode-select -p 2>/dev/null)),)
    DEVELOPER_DIR := $(firstword $(wildcard /Applications/Xcode.app/Contents/Developer /Applications/Xcode-beta.app/Contents/Developer))
  endif
endif
export DEVELOPER_DIR

PROJECT   := OpenTaskManager.xcodeproj
SCHEME    := OpenTaskManager
TEST_SCHEME := OpenTaskManagerLogicTests
DERIVED   := .build/xcode
DEST      := platform=macOS,arch=$(shell uname -m)
APP_DEBUG := $(DERIVED)/Build/Products/Debug/OpenTaskManager.app
APP_REL   := $(DERIVED)/Build/Products/Release/OpenTaskManager.app
KIT       := Packages/OTMKit

.PHONY: help generate build release run test test-app coverage cli install-cli icon lint lint-automation test-scripts clean package

help:
	@echo "make package VERSION=x.y.z  Build a signed universal ZIP and checksum locally"
	@echo "make generate     Generate $(PROJECT) from project.yml (needs xcodegen)"
	@echo "make build        Debug build of the app"
	@echo "make run          Build and launch the app"
	@echo "make release      Release build of the app"
	@echo "make test         Run OTMKit and hostless app logic tests"
	@echo "make test-app     Run hostless app logic tests"
	@echo "make coverage     Run OTMKit tests and report source line coverage"
	@echo "make cli          Build the otm command-line tool (release)"
	@echo "make install-cli  Copy otm to /usr/local/bin"
	@echo "make icon         Re-render the app icon"
	@echo "make lint         Run SwiftLint"
	@echo "make lint-automation  Run actionlint and ShellCheck on workflows and scripts"
	@echo "make test-scripts Run the release script checks (needs only bash and git)"

generate:
	xcodegen generate --quiet

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) -destination "$(DEST)" -quiet build

release: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED) -destination "$(DEST)" -quiet build
	@echo "Built $(APP_REL)"

run: build
	@pkill -x OpenTaskManager 2>/dev/null || true
	open $(APP_DEBUG)

test:
	swift test --package-path $(KIT)
	$(MAKE) test-app

# xcodebuild runs the test bundle through a test runner that may not be
# allowed into ~/Documents (or another protected folder holding the clone):
# it then reports the bundle's executable "couldn't be located". So the
# bundle is built in the temporary folder, one per checkout.
TEST_DERIVED ?= $(or $(TMPDIR),/tmp/)OpenTaskManagerLogicTests-$(notdir $(CURDIR))

test-app: generate
	xcodebuild -project $(PROJECT) -scheme $(TEST_SCHEME) -configuration Debug -derivedDataPath "$(TEST_DERIVED)" -destination "$(DEST)" -quiet test

coverage:
	bash scripts/coverage.sh

cli:
	swift build --package-path $(KIT) -c release --product otm
	@echo "Built $(KIT)/.build/release/otm"

install-cli: cli
	install -m 755 $(KIT)/.build/release/otm /usr/local/bin/otm

icon:
	swift scripts/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset

lint:
	swiftlint lint --strict --quiet

# Needs actionlint and shellcheck (`brew install actionlint shellcheck`);
# actionlint runs shellcheck on the workflows' scripts as well.
lint-automation:
	actionlint
	shellcheck scripts/*.sh cross/scripts/*.sh

test-scripts:
	bash scripts/test-release-source.sh

clean:
	rm -rf .build $(KIT)/.build $(PROJECT)

# Requires a clean checkout; only creates local artifacts.
package:
	bash scripts/package-release.sh "$(VERSION)"
