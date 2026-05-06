BUILD_DIR := build
APP_BUNDLE := $(BUILD_DIR)/XDial.app

.PHONY: all helper app clean

all: helper app

helper:
	@mkdir -p $(BUILD_DIR)
	go build -o $(BUILD_DIR)/xdial-helper ./cmd/xdial-helper/

app: helper
	cd macos && swift build --build-path ../$(BUILD_DIR)/macos
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Library/LaunchDaemons"
	@cp $(BUILD_DIR)/macos/debug/XDial "$(APP_BUNDLE)/Contents/MacOS/XDial"
	@cp $(BUILD_DIR)/xdial-helper "$(APP_BUNDLE)/Contents/MacOS/xdial-helper"
	@cp macos/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@codesign -s - -f "$(APP_BUNDLE)"

clean:
	rm -rf $(BUILD_DIR)
