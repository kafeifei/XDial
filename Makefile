BUILD_DIR := build
APP_BUNDLE := $(BUILD_DIR)/XDial.app
GOBIN := $(shell go env GOPATH)/bin

.PHONY: all cli app inspector clean test test-smoke libbox-xcframework appletv

# with_gvisor:core/libbox 的离线数据面集成测试(dataplane_test.go)需要 sing-tun 的
# gVisor 用户态栈才能在纯内存里跑通 TUN→路由→outbound 链路(system 栈依赖 OS 内核
# 回环,离线 fake tun 用不了)。该 tag 也是 tvOS NE 真机运行时实际需要的栈,加在这里
# 不影响其它包。
test:
	go test -tags with_gvisor ./core/... -v -count=1

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

# 把 core/libbox(sslcon + gVisor + sing-box,进程内 tvOS 引擎)编译成
# Swift 可直接 import 的 xcframework。需要 SagerNet fork 的 gomobile/gobind:
#   go install github.com/sagernet/gomobile/cmd/gomobile@latest
#   go install github.com/sagernet/gomobile/cmd/gobind@latest
libbox-xcframework:
	@mkdir -p $(BUILD_DIR)
	rm -rf $(BUILD_DIR)/Libbox.xcframework
	PATH="$(PATH):$(GOBIN)" GOFLAGS=-mod=mod gomobile bind -target=tvos -o $(BUILD_DIR)/Libbox.xcframework ./core/libbox

# 构建 tvOS app(appletv/ 下的 xcodegen 工程,双 target:app + NE 扩展)。
# 依赖 libbox-xcframework 先产出 build/Libbox.xcframework(project.yml 引用路径)。
# 只编 Simulator,真机需要签名和账号(暂未到位)。需要 xcodegen:
#   brew install xcodegen
appletv: libbox-xcframework
	@command -v xcodegen >/dev/null 2>&1 || { echo "error: xcodegen not found. Install it with: brew install xcodegen"; exit 1; }
	cd appletv && xcodegen generate
	cd appletv && xcodebuild -project XDialTV.xcodeproj -scheme XDialTV -sdk appletvsimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build

clean:
	rm -rf $(BUILD_DIR)
