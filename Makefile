BUILD_DIR := build
APP_BUNDLE := $(BUILD_DIR)/XDial.app
RELEASE_BUNDLE := $(BUILD_DIR)/release/XDial.app
GOBIN := $(shell go env GOPATH)/bin
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
PLIST_VERSION := $(patsubst v%,%,$(VERSION))
GO_LDFLAGS := -X main.version=$(VERSION)
# macOS 只会替换构建号更高的 System Extension。Debug 构建若反复使用
# project.yml 里的固定号，宿主 App 虽然已经更新，Provider 仍可能继续运行旧代码，
# 而 properties API 又会因为版本号相同误报 ready。一次 make 调用内复用同一个
# Unix 时间戳，确保 host 与 extension 配套且每次本地构建都能被系统识别为升级。
DEBUG_BUILD_VERSION ?= $(shell date +%s)
DESKTOP_GO_TAGS := with_gvisor,with_utls
MOBILE_LIBBOX_TAGS := with_gvisor,with_utls
MACOS_LIBBOX_FRAMEWORK := $(BUILD_DIR)/frameworks/macos/Libbox.xcframework
MACOS_LIBBOX_BINARY := $(MACOS_LIBBOX_FRAMEWORK)/macos-arm64_x86_64/Libbox.framework/Libbox
LIBBOX_GO_SOURCES := $(shell find core -type f -name '*.go' ! -name '*_test.go')
PATCHED_GO_SCRIPT := scripts/prepare-patched-go-mod.sh
PATCHED_GO_DIR := $(abspath $(BUILD_DIR)/patched-go)
PATCHED_MODFILE := $(PATCHED_GO_DIR)/xdial.mod
PATCHED_WORKFILE := $(PATCHED_GO_DIR)/xdial.work
PATCHED_GO_INPUTS_CURRENT := $(shell bash $(PATCHED_GO_SCRIPT) --check >/dev/null 2>&1 && printf yes)
# gomobile replaces GOFLAGS in its per-architecture child process. GOWORK is
# preserved, so it is the authoritative mapping to the patched Tailscale module.
PATCHED_GO_ENV = GOWORK='$(PATCHED_WORKFILE)' GOFLAGS=
SING_BOX_TEST_BINARY := $(abspath $(BUILD_DIR)/tools/sing-box)
MACOS_ICON_GENERATOR := scripts/generate-macos-app-icon/main.swift
MACOS_ICON_SOURCE := macos/Sources/XDial/AppIcon.swift
# SMAppService 要求签名身份跨构建稳定：ad-hoc 签名每次构建身份都变，
# 系统会把重编后的 daemon 当新程序、要求重新批准。默认用开发者证书
# （partial match，本机唯一），无证书环境可 SIGN_IDENTITY=- 回落 ad-hoc。
SIGN_IDENTITY ?= Apple Development

.PHONY: all cli app ci-macos-build release restart inspector clean prepare-patched-go go-vet go-build test test-patched-tailscale test-patched-sing-box test-patched-sslcon test-macos-transaction test-smoke sing-box-test-validator check-mobile-libbox-deps libbox-xcframework libbox-ios-xcframework libbox-macos-xcframework appletv ios FORCE_PATCHED_GO

macos/AppIcon.icns: $(MACOS_ICON_SOURCE) $(MACOS_ICON_GENERATOR)
	@rm -rf "$(BUILD_DIR)/AppIcon.iconset" "$(BUILD_DIR)/generate-app-icon"
	@mkdir -p "$(BUILD_DIR)/AppIcon.iconset"
	xcrun swiftc $(MACOS_ICON_SOURCE) $(MACOS_ICON_GENERATOR) \
		-o "$(BUILD_DIR)/generate-app-icon"
	"$(BUILD_DIR)/generate-app-icon" "$(BUILD_DIR)/AppIcon.iconset"
	iconutil -c icns "$(BUILD_DIR)/AppIcon.iconset" \
		-o macos/AppIcon.icns

# 组装 .app bundle。$(1)=swift 产物目录(debug/release) $(2)=bundle 路径
define assemble_app
	@mkdir -p "$(2)/Contents/MacOS" "$(2)/Contents/Resources" "$(2)/Contents/Library/LaunchDaemons"
	@cp $(BUILD_DIR)/macos/$(1)/XDial "$(2)/Contents/MacOS/XDial"
	@cp $(BUILD_DIR)/xdial "$(2)/Contents/MacOS/xdial-daemon"
	@cp macos/Info.plist "$(2)/Contents/Info.plist"
	@cp macos/AppIcon.icns "$(2)/Contents/Resources/AppIcon.icns"
	@cp macos/com.kafeifei.xdial.helper.plist "$(2)/Contents/Library/LaunchDaemons/"
	@plutil -replace CFBundleExecutable -string XDial "$(2)/Contents/Info.plist"
	@plutil -replace CFBundleIdentifier -string com.kafeifei.xdial "$(2)/Contents/Info.plist"
	@plutil -replace CFBundleName -string XDial "$(2)/Contents/Info.plist"
	@plutil -replace CFBundleVersion -string "$(PLIST_VERSION)" "$(2)/Contents/Info.plist"
	@plutil -replace CFBundleShortVersionString -string "$(PLIST_VERSION)" "$(2)/Contents/Info.plist"
	@plutil -replace LSMinimumSystemVersion -string "15.0" "$(2)/Contents/Info.plist"
	@codesign -f -s "$(SIGN_IDENTITY)" -i com.kafeifei.xdial.helper --entitlements macos/XDialDaemon.entitlements "$(2)/Contents/MacOS/xdial-daemon"
	@codesign -f -s "$(SIGN_IDENTITY)" "$(2)"
endef

# with_gvisor:core/libbox 的离线数据面集成测试(dataplane_test.go)需要 sing-tun 的
# gVisor 用户态栈才能在纯内存里跑通 TUN→路由→outbound 链路(system 栈依赖 OS 内核
# 回环,离线 fake tun 用不了)。该 tag 也是 tvOS NE 真机运行时实际需要的栈,加在这里
# 不影响其它包。
# Parse-time content validation avoids timestamp-only patch deletion checks. A
# stale input set gains a phony prerequisite, so Make propagates the rebuilt
# workfile to downstream XCFramework rules; a fresh set remains untouched.
ifneq ($(PATCHED_GO_INPUTS_CURRENT),yes)
$(PATCHED_WORKFILE): FORCE_PATCHED_GO
endif
$(PATCHED_WORKFILE):
	bash $(PATCHED_GO_SCRIPT)

prepare-patched-go: $(PATCHED_WORKFILE)

go-vet: $(PATCHED_WORKFILE)
	$(PATCHED_GO_ENV) go vet ./...

go-build: $(PATCHED_WORKFILE)
	$(PATCHED_GO_ENV) go build ./...

test-patched-tailscale: $(PATCHED_WORKFILE)
	$(PATCHED_GO_ENV) go test \
		github.com/sagernet/tailscale/derp/derphttp \
		github.com/sagernet/tailscale/wgengine/magicsock \
		github.com/sagernet/tailscale/ipn/ipnlocal \
		-run '^(TestResetNetInfoLast|TestDERPActiveWaitsForStartGate|TestXDial.*)$$' \
		-count=1

test-patched-sing-box: $(PATCHED_WORKFILE)
	$(PATCHED_GO_ENV) go test -tags '$(DESKTOP_GO_TAGS)' \
		github.com/sagernet/sing-box/protocol/tailscale \
		github.com/sagernet/sing-box/dns/transport/hosts \
		github.com/sagernet/sing-box/protocol/socks \
		-run '^TestXDial.*$$' \
		-count=1

test-patched-sslcon: $(PATCHED_WORKFILE)
	cd $(PATCHED_GO_DIR)/sslcon && \
		GOWORK='$(PATCHED_WORKFILE)' GOFLAGS= go test -race \
			./session ./vpn -count=1

test: $(PATCHED_WORKFILE) test-patched-tailscale test-patched-sing-box test-patched-sslcon sing-box-test-validator
	PATH="$(dir $(SING_BOX_TEST_BINARY)):$(PATH)" $(PATCHED_GO_ENV) go test -tags '$(MOBILE_LIBBOX_TAGS)' ./core/... -v -count=1

test-macos-transaction:
	@! rg -n 'probeNetwork|127\.0\.0\.1:9090|test-out' macos/Sources/XDial
	@! rg -n 'willSleepNotification|screensDidSleepNotification|systemIsSleeping|sawUnavailablePath' macos/Sources/XDial macos/Shared
	@! rg -n 'URLSession|ip-api\.com' macos/Sources/XDial/NetworkInfo.swift
	@! rg -U -n '\.on(Appear|Disappear)[[:space:]]*\{[^}]{0,500}(probeNetwork|prepareTailscale|closeTailscaleSetup|URLSession|127\.0\.0\.1:9090)' macos/Sources/XDial/SettingsView.swift
	@test "$$(rg -U -o 'AXUIElementCopyAttributeValue\([^)]*kAXValueAttribute' macos/Sources/XDial/DebugServer.swift | wc -l | tr -d ' ')" -eq 1
	@rg -U -q 'private static func safeAXValue\([^}]+guard subrole != secureTextFieldSubrole else \{ return nil \}[^}]+AXUIElementCopyAttributeValue\([^)]*kAXValueAttribute' macos/Sources/XDial/DebugServer.swift
	@rg -q 'safeAXValue\(el, subrole: subrole\)' macos/Sources/XDial/DebugServer.swift
	@rg -q 'safeAXStringValue\(' macos/Sources/XDial/DebugServer.swift
	@! rg -n 'str\([^)]*kAXValueAttribute' macos/Sources/XDial/DebugServer.swift
	@test "$$(rg -n 'statusHandler\?\(' macos/Sources/XDial/TransparentProxyManager.swift | wc -l | tr -d ' ')" -eq 1
	@rg -U -q 'private func publishRuntimeStatus\([^}]+TransparentProxyRuntimeGate\.resolve' macos/Sources/XDial/TransparentProxyManager.swift
	cd macos && xcodegen generate
	xcodebuild -project macos/XDial.xcodeproj -scheme XDialTests \
		-configuration Debug -destination 'platform=macOS,arch=arm64' \
		-derivedDataPath $(BUILD_DIR)/macos-tests test

test-smoke: $(PATCHED_WORKFILE) sing-box-test-validator
	PATH="$(dir $(SING_BOX_TEST_BINARY)):$(PATH)" $(PATCHED_GO_ENV) go test ./core/config/ -run TestSmoke -v -count=1 -timeout 120s

all: cli app

cli: $(PATCHED_WORKFILE)
	@mkdir -p $(BUILD_DIR)
	$(PATCHED_GO_ENV) go build -tags '$(DESKTOP_GO_TAGS)' -ldflags "$(GO_LDFLAGS)" -o $(BUILD_DIR)/xdial ./cmd/xdial/

# debug 构建(含 DebugServer,仅本地开发用,不得分发)
app: cli libbox-macos-xcframework macos/AppIcon.icns
	cd macos && xcodegen generate
	xcodebuild -project macos/XDial.xcodeproj -scheme XDialTransparentProxy -configuration Debug \
		-destination 'platform=macOS,arch=arm64' \
		-derivedDataPath $(BUILD_DIR)/macos-xcode \
		CURRENT_PROJECT_VERSION=$(DEBUG_BUILD_VERSION) \
		build
	xcodebuild -project macos/XDial.xcodeproj -scheme XDial -configuration Debug \
		-destination 'platform=macOS,arch=arm64' \
		-derivedDataPath $(BUILD_DIR)/macos-xcode \
		CURRENT_PROJECT_VERSION=$(DEBUG_BUILD_VERSION) \
		build
	rm -rf "$(APP_BUNDLE)"
	ditto "$(BUILD_DIR)/macos-xcode/Build/Products/Debug/XDial.app" "$(APP_BUNDLE)"

# GitHub 托管 runner 不持有 System Extension 的签名证书和 provisioning profile。
# 这里分别编译 Debug / Release 的扩展与宿主，只验证源码和链接；产物没有签名、不可分发。
ci-macos-build: cli libbox-macos-xcframework macos/AppIcon.icns
	cd macos && xcodegen generate
	@set -e; for configuration in Debug Release; do \
		xcodebuild -project macos/XDial.xcodeproj -scheme XDialTransparentProxy \
			-configuration "$$configuration" -destination 'platform=macOS,arch=arm64' \
			-derivedDataPath $(BUILD_DIR)/macos-xcode-ci CODE_SIGNING_ALLOWED=NO build; \
		xcodebuild -project macos/XDial.xcodeproj -scheme XDial \
			-configuration "$$configuration" -destination 'platform=macOS,arch=arm64' \
			-derivedDataPath $(BUILD_DIR)/macos-xcode-ci CODE_SIGNING_ALLOWED=NO build; \
	done

# release 构建:swift -c release 使 #if DEBUG 的 DebugServer 整体排除,
# go -trimpath -s -w 去符号并注入版本。分发一律用这个产物。
release: libbox-macos-xcframework macos/AppIcon.icns
	@mkdir -p $(BUILD_DIR)
	$(PATCHED_GO_ENV) go build -tags '$(DESKTOP_GO_TAGS)' -trimpath -ldflags "$(GO_LDFLAGS) -s -w" -o $(BUILD_DIR)/xdial ./cmd/xdial/
	cd macos && xcodegen generate
	xcodebuild -project macos/XDial.xcodeproj -scheme XDialTransparentProxy -configuration Release \
		-destination 'platform=macOS,arch=arm64' \
		-derivedDataPath $(BUILD_DIR)/macos-xcode-release \
		build
	xcodebuild -project macos/XDial.xcodeproj -scheme XDial -configuration Release \
		-destination 'platform=macOS,arch=arm64' \
		-derivedDataPath $(BUILD_DIR)/macos-xcode-release \
		build
	rm -rf "$(RELEASE_BUNDLE)"
	ditto "$(BUILD_DIR)/macos-xcode-release/Build/Products/Release/XDial.app" "$(RELEASE_BUNDLE)"
	@echo "release bundle: $(RELEASE_BUNDLE) (version $(PLIST_VERSION))"

# 一键重启：先完整构建并签名新版本，成功后才让旧实例完成网络回滚并退出。
# 构建目录中的进程紧接着执行无 UI 的原子安装，然后只启动
# /Applications 中的最终版本。外网验收必须放在新事务提交之后，
# 不得在旧实例退出与新实例启动之间扩大断网窗口。
# 构建失败不得影响正在运行的旧实例。
restart:
	@$(MAKE) app DEBUG_BUILD_VERSION=$(DEBUG_BUILD_VERSION)
	@bash scripts/restart-macos-app.sh "$(abspath $(APP_BUNDLE))"

inspector:
	@mkdir -p $(BUILD_DIR)
	swiftc -O tools/inspector.swift -o $(BUILD_DIR)/xdial-inspector

# 把 core/libbox(sslcon + gVisor + sing-box,进程内 tvOS 引擎)编译成
# Swift 可直接 import 的 xcframework。需要 SagerNet fork 的 gomobile/gobind:
#   go install github.com/sagernet/gomobile/cmd/gomobile@latest
#   go install github.com/sagernet/gomobile/cmd/gobind@latest
check-mobile-libbox-deps: $(PATCHED_WORKFILE)
	@deps="$$(GOOS=ios GOARCH=arm64 CGO_ENABLED=1 $(PATCHED_GO_ENV) go list -deps -tags '$(MOBILE_LIBBOX_TAGS)' ./core/libbox)" || exit 1; \
	if ! printf '%s\n' "$$deps" | grep -Eq '^github\.com/sagernet/sing-box/protocol/tailscale$$'; then \
		echo 'error: mobile Libbox is missing the sing-box Tailscale endpoint'; exit 1; \
	fi; \
	if ! printf '%s\n' "$$deps" | grep -Eq '^github\.com/sagernet/tailscale(/|$$)'; then \
		echo 'error: mobile Libbox is missing the Tailscale data plane'; exit 1; \
	fi; \
	if ! printf '%s\n' "$$deps" | grep -Eq '^github\.com/metacubex/utls$$'; then \
		echo 'error: mobile Libbox is missing uTLS client fingerprint support'; exit 1; \
	fi

libbox-xcframework: check-mobile-libbox-deps
	@mkdir -p $(BUILD_DIR)
	rm -rf $(BUILD_DIR)/Libbox.xcframework
	PATH="$(PATH):$(GOBIN)" $(PATCHED_GO_ENV) gomobile bind -tags '$(MOBILE_LIBBOX_TAGS)' -target=tvos -o $(BUILD_DIR)/Libbox.xcframework ./core/libbox
	@if find $(BUILD_DIR)/Libbox.xcframework -type f -name Libbox -exec strings {} \; | grep -Fq 'gVisor is not included in this build'; then \
		echo 'error: Libbox was built without the gVisor data stack'; exit 1; \
	fi
	@if find $(BUILD_DIR)/Libbox.xcframework -type f -name Libbox -exec strings {} \; | grep -Fq 'uTLS is not included in this build'; then \
		echo 'error: Libbox was built without uTLS client fingerprint support'; exit 1; \
	fi

# iOS 使用独立 XCFramework，避免 iOS/tvOS slice 互相覆盖。
libbox-ios-xcframework: check-mobile-libbox-deps
	@mkdir -p $(BUILD_DIR)/frameworks/ios
	rm -rf $(BUILD_DIR)/frameworks/ios/Libbox.xcframework
	PATH="$(PATH):$(GOBIN)" $(PATCHED_GO_ENV) gomobile bind -tags '$(MOBILE_LIBBOX_TAGS)' -target=ios -o $(BUILD_DIR)/frameworks/ios/Libbox.xcframework ./core/libbox
	@if find $(BUILD_DIR)/frameworks/ios/Libbox.xcframework -type f -name Libbox -exec strings {} \; | grep -Fq 'gVisor is not included in this build'; then \
		echo 'error: Libbox was built without the gVisor data stack'; exit 1; \
	fi
	@if find $(BUILD_DIR)/frameworks/ios/Libbox.xcframework -type f -name Libbox -exec strings {} \; | grep -Fq 'uTLS is not included in this build'; then \
		echo 'error: Libbox was built without uTLS client fingerprint support'; exit 1; \
	fi

# macOS Transparent Proxy 与移动端复用同一个进程内 Libbox 数据面。用文件依赖保证
# core 变化后桌面构建不会继续链接旧 XCFramework。
libbox-macos-xcframework: $(MACOS_LIBBOX_BINARY)

$(MACOS_LIBBOX_BINARY): $(LIBBOX_GO_SOURCES) go.mod go.sum Makefile $(PATCHED_WORKFILE)
	$(MAKE) check-mobile-libbox-deps
	@mkdir -p $(BUILD_DIR)/frameworks/macos
	rm -rf $(MACOS_LIBBOX_FRAMEWORK) \
		$(BUILD_DIR)/macos-amd64 \
		$(BUILD_DIR)/macos-arm64
	PATH="$(PATH):$(GOBIN)" $(PATCHED_GO_ENV) gomobile bind -tags '$(MOBILE_LIBBOX_TAGS)' -target=macos -o $(MACOS_LIBBOX_FRAMEWORK) ./core/libbox
	@if find $(MACOS_LIBBOX_FRAMEWORK) -type f -name Libbox -exec strings {} \; | grep -Fq 'gVisor is not included in this build'; then \
		echo 'error: Libbox was built without the gVisor data stack'; exit 1; \
	fi
	@if find $(MACOS_LIBBOX_FRAMEWORK) -type f -name Libbox -exec strings {} \; | grep -Fq 'uTLS is not included in this build'; then \
		echo 'error: Libbox was built without uTLS client fingerprint support'; exit 1; \
	fi

$(SING_BOX_TEST_BINARY): Makefile $(PATCHED_WORKFILE)
	@mkdir -p $(dir $(SING_BOX_TEST_BINARY))
	$(PATCHED_GO_ENV) go build -tags 'with_gvisor,with_utls,with_clash_api,with_tailscale' \
		-o $(SING_BOX_TEST_BINARY) github.com/sagernet/sing-box/cmd/sing-box

sing-box-test-validator: $(SING_BOX_TEST_BINARY)

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

FORCE_PATCHED_GO:
