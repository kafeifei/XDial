BUILD_DIR := build
APP_BUNDLE := $(BUILD_DIR)/XDial.app

.PHONY: all cli app inspector clean test test-smoke

test:
	go test ./core/... -v -count=1

test-smoke:
	go test ./core/config/ -run TestSmoke -v -count=1 -timeout 120s

all: cli app

cli:
	@mkdir -p $(BUILD_DIR)
	go build -o $(BUILD_DIR)/xdial ./cmd/xdial/

app: cli
	cd macos && swift build --build-path ../$(BUILD_DIR)/macos
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Library/LaunchDaemons"
	@cp $(BUILD_DIR)/macos/debug/XDial "$(APP_BUNDLE)/Contents/MacOS/XDial"
	@cp $(BUILD_DIR)/xdial "$(APP_BUNDLE)/Contents/MacOS/xdial-daemon"
	@cp macos/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp macos/AppIcon.icns "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	@codesign -s - -f "$(APP_BUNDLE)"

inspector:
	@mkdir -p $(BUILD_DIR)
	swiftc -O tools/inspector.swift -o $(BUILD_DIR)/xdial-inspector

clean:
	rm -rf $(BUILD_DIR)
