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
DERIVED   := .build/xcode
DEST      := platform=macOS,arch=$(shell uname -m)
APP_DEBUG := $(DERIVED)/Build/Products/Debug/OpenTaskManager.app
APP_REL   := $(DERIVED)/Build/Products/Release/OpenTaskManager.app
KIT       := Packages/OTMKit

.PHONY: help generate build release run test coverage cli install-cli icon lint clean

help:
	@echo "make generate     Generate $(PROJECT) from project.yml (needs xcodegen)"
	@echo "make build        Debug build of the app"
	@echo "make run          Build and launch the app"
	@echo "make release      Release build of the app"
	@echo "make test         Run the OTMKit test suite"
	@echo "make coverage     Run OTMKit tests and report source line coverage"
	@echo "make cli          Build the otm command-line tool (release)"
	@echo "make install-cli  Copy otm to /usr/local/bin"
	@echo "make icon         Re-render the app icon"
	@echo "make lint         Run SwiftLint"

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

clean:
	rm -rf .build $(KIT)/.build $(PROJECT)
