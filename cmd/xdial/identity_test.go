package main

import (
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"testing"
)

func TestRuntimeIdentityForDebug(t *testing.T) {
	got := runtimeIdentityForFlavor("debug")
	want := runtimeIdentity{
		hostBundleIdentifier:   "com.kafeifei.xdial.debug",
		helperBundleIdentifier: "com.kafeifei.xdial.debug.helper",
		daemonLabel:            "com.kafeifei.xdial.debug.daemon",
		socketPath:             "/tmp/xdial-debug.sock",
		engineBasePath:         "/tmp/xdial-debug-engine",
		rootStatePath:          "/Library/Application Support/XDial Debug",
		userStateDirectoryName: ".xdial-debug",
		sharedAppGroup:         "UVZM439VGU.com.kafeifei.xdial.debug.network",
		registrationIntentPath: "/tmp/xdial-debug-registration-maintenance",
		logPath:                "/tmp/xdial-debug.log",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("debug runtime identity = %#v, want %#v", got, want)
	}
	if got.userStatePath("/Users/test") != "/Users/test/.xdial-debug" {
		t.Fatalf("debug user state path = %q", got.userStatePath("/Users/test"))
	}
}

func TestRuntimeIdentityDefaultsToExistingProductionIdentity(t *testing.T) {
	want := runtimeIdentity{
		hostBundleIdentifier:   "com.kafeifei.xdial.app",
		helperBundleIdentifier: "com.kafeifei.xdial.app.helper",
		daemonLabel:            "com.kafeifei.xdial.app.daemon",
		socketPath:             "/tmp/xdial.sock",
		engineBasePath:         filepath.Join(os.TempDir(), "xdial-engine"),
		rootStatePath:          "/Library/Application Support/XDial",
		userStateDirectoryName: ".xdial",
		sharedAppGroup:         "UVZM439VGU.com.kafeifei.xdial.network",
		registrationIntentPath: "/tmp/xdial-registration-maintenance",
		logPath:                "/tmp/xdial.log",
	}
	for _, flavor := range []string{"", "release", "unexpected"} {
		t.Run(flavor, func(t *testing.T) {
			got := runtimeIdentityForFlavor(flavor)
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("runtime identity for %q = %#v, want %#v", flavor, got, want)
			}
			if got.userStatePath("/Users/test") != "/Users/test/.xdial" {
				t.Fatalf("production user state path = %q", got.userStatePath("/Users/test"))
			}
		})
	}
}

func TestOrphanSingBoxPatternsAreFlavorScoped(t *testing.T) {
	formal := runtimeIdentityForFlavor("")
	debug := runtimeIdentityForFlavor("debug")
	formalPattern := regexp.MustCompile(formal.orphanSingBoxPattern())
	debugPattern := regexp.MustCompile(debug.orphanSingBoxPattern())

	formalCommand := "sing-box run -c /tmp/xdial-engine/sing-box.json -D /tmp/xdial-engine"
	debugCommand := "sing-box run -c /tmp/xdial-debug-engine/sing-box.json -D /tmp/xdial-debug-engine"
	if !formalPattern.MatchString(formalCommand) || formalPattern.MatchString(debugCommand) {
		t.Fatalf("formal cleanup pattern %q is not isolated", formal.orphanSingBoxPattern())
	}
	if !debugPattern.MatchString(debugCommand) || debugPattern.MatchString(formalCommand) {
		t.Fatalf("debug cleanup pattern %q is not isolated", debug.orphanSingBoxPattern())
	}
}
