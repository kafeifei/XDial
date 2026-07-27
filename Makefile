BUILD_DIR := build
APP_BUNDLE := $(BUILD_DIR)/XDial.app
RELEASE_BUNDLE := $(BUILD_DIR)/release/XDial.app
GOBIN := $(shell go env GOPATH)/bin
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
PLIST_VERSION := $(patsubst v%,%,$(VERSION))
GO_LDFLAGS := -X main.version=$(VERSION)
MOBILE_LIBBOX_TAGS := with_gvisor
# SMAppService 要求签名身份跨构建稳定：ad-hoc 签名每次构建身份都变，
# 系统会把重编后的 daemon 当新程序、要求重新批准。默认用开发者证书
# （partial match，本机唯一），无证书环境可 SIGN_IDENTITY=- 回落 ad-hoc。
SIGN_IDENTITY ?= Apple Development

.PHONY: all cli app release restart inspector clean test test-smoke check-mobile-libbox-deps libbox-xcframework libbox-ios-xcframework appletv ios

# 组装 .app bundle。$(1)=swift 产物目录(debug/release) $(2)=bundle 路径
define assemble_app
	@mkdir -p "$(2)/Contents/MacOS" "$(2)/Contents/Resources" "$(2)/Contents/Library/LaunchDaemons"
	@cp $(BUILD_DIR)/macos/$(1)/XDial "$(2)/Contents/MacOS/XDial"
	@cp $(BUILD_DIR)/xdial "$(2)/Contents/MacOS/xdial-daemon"
	@cp macos/Info.plist "$(2)/Contents/Info.plist"
	@cp macos/AppIcon.icns "$(2)/Contents/Resources/AppIcon.icns"
	@cp macos/com.kafeifei.xdial.helper.plist "$(2)/Contents/Library/LaunchDaemons/"
	@plutil -replace CFBundleShortVersionString -string "$(PLIST_VERSION)" "$(2)/Contents/Info.plist"
	@codesign -f -s "$(SIGN_IDENTITY)" -i com.kafeifei.xdial.helper "$(2)/Contents/MacOS/xdial-daemon"
	@codesign -f -s "$(SIGN_IDENTITY)" "$(2)"
endef

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
	go build -ldflags "$(GO_LDFLAGS)" -o $(BUILD_DIR)/xdial ./cmd/xdial/

# debug 构建(含 DebugServer,仅本地开发用,不得分发)
app: cli
	cd macos && swift build --build-path ../$(BUILD_DIR)/macos
	$(call assemble_app,debug,$(APP_BUNDLE))

# release 构建:swift -c release 使 #if DEBUG 的 DebugServer 整体排除,
# go -trimpath -s -w 去符号并注入版本。分发一律用这个产物。
release:
	@mkdir -p $(BUILD_DIR)
	go build -trimpath -ldflags "$(GO_LDFLAGS) -s -w" -o $(BUILD_DIR)/xdial ./cmd/xdial/
	cd macos && swift build -c release --build-path ../$(BUILD_DIR)/macos
	$(call assemble_app,release,$(RELEASE_BUNDLE))
	@echo "release bundle: $(RELEASE_BUNDLE) (version $(PLIST_VERSION))"

# 一键重启:杀旧实例→重编→启动→等 debug server 上线(所有等待有超时)
restart: app
	@pkill -x XDial 2>/dev/null || true
	@for i in $$(seq 1 20); do pgrep -x XDial >/dev/null || break; sleep 0.2; done
	@open $(APP_BUNDLE)
	@for i in $$(seq 1 30); do \
		if curl -s -m 1 http://127.0.0.1:19876/health >/dev/null 2>&1; then \
			echo "✓ XDial restarted, debug server ready"; exit 0; fi; \
		sleep 0.5; \
	done; echo "✗ debug server not up after 15s"; exit 1

inspector:
	@mkdir -p $(BUILD_DIR)
	swiftc -O tools/inspector.swift -o $(BUILD_DIR)/xdial-inspector

# 把 core/libbox(sslcon + gVisor + sing-box,进程内 tvOS 引擎)编译成
# Swift 可直接 import 的 xcframework。需要 SagerNet fork 的 gomobile/gobind:
#   go install github.com/sagernet/gomobile/cmd/gomobile@latest
#   go install github.com/sagernet/gomobile/cmd/gobind@latest
check-mobile-libbox-deps:
	@deps="$$(GOOS=ios GOARCH=arm64 CGO_ENABLED=1 GOFLAGS=-mod=mod go list -deps -tags '$(MOBILE_LIBBOX_TAGS)' ./core/libbox)" || exit 1; \
	if ! printf '%s\n' "$$deps" | grep -Eq '^github\.com/sagernet/sing-box/protocol/tailscale$$'; then \
		echo 'error: mobile Libbox is missing the sing-box Tailscale endpoint'; exit 1; \
	fi; \
	if ! printf '%s\n' "$$deps" | grep -Eq '^github\.com/sagernet/tailscale(/|$$)'; then \
		echo 'error: mobile Libbox is missing the Tailscale data plane'; exit 1; \
	fi

libbox-xcframework: check-mobile-libbox-deps
	@mkdir -p $(BUILD_DIR)
	rm -rf $(BUILD_DIR)/Libbox.xcframework
	PATH="$(PATH):$(GOBIN)" GOFLAGS=-mod=mod gomobile bind -tags '$(MOBILE_LIBBOX_TAGS)' -target=tvos -o $(BUILD_DIR)/Libbox.xcframework ./core/libbox
	@if find $(BUILD_DIR)/Libbox.xcframework -type f -name Libbox -exec strings {} \; | grep -Fq 'gVisor is not included in this build'; then \
		echo 'error: Libbox was built without the gVisor data stack'; exit 1; \
	fi

# iOS 使用独立 XCFramework，避免 iOS/tvOS slice 互相覆盖。
libbox-ios-xcframework: check-mobile-libbox-deps
	@mkdir -p $(BUILD_DIR)/frameworks/ios
	rm -rf $(BUILD_DIR)/frameworks/ios/Libbox.xcframework
	PATH="$(PATH):$(GOBIN)" GOFLAGS=-mod=mod gomobile bind -tags '$(MOBILE_LIBBOX_TAGS)' -target=ios -o $(BUILD_DIR)/frameworks/ios/Libbox.xcframework ./core/libbox
	@if find $(BUILD_DIR)/frameworks/ios/Libbox.xcframework -type f -name Libbox -exec strings {} \; | grep -Fq 'gVisor is not included in this build'; then \
		echo 'error: Libbox was built without the gVisor data stack'; exit 1; \
	fi

# 构建 tvOS app(appletv/ 下的 xcodegen 工程,双 target:app + NE 扩展)。
# 依赖 libbox-xcframework 先产出 build/Libbox.xcframework(project.yml 引用路径)。
# 只编 Simulator,真机需要签名和账号(暂未到位)。需要 xcodegen:
#   brew install xcodegen
appletv: libbox-xcframework
	@command -v xcodegen >/dev/null 2>&1 || { echo "error: xcodegen not found. Install it with: brew install xcodegen"; exit 1; }
	cd appletv && xcodegen generate
	cd appletv && xcodebuild -project XDialTV.xcodeproj -scheme XDialTV -sdk appletvsimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build

# 构建 iOS App + Packet Tunnel Extension。模拟器走 FakeTunnel，真机由 Xcode 自动签名。
ios: libbox-ios-xcframework
	@command -v xcodegen >/dev/null 2>&1 || { echo "error: xcodegen not found. Install it with: brew install xcodegen"; exit 1; }
	cd ios && xcodegen generate
	xcodebuild -project ios/XDialIOS.xcodeproj -scheme XDialIOS -sdk iphonesimulator -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath $(BUILD_DIR)/ios CODE_SIGNING_ALLOWED=NO build

clean:
	rm -rf $(BUILD_DIR)
