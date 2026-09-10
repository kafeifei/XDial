package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
)

func TestRegistrationHandoffPreservesInFlightWork(t *testing.T) {
	gate := &daemonRegistrationGate{}
	if !gate.beginWork() {
		t.Fatal("initial work refused")
	}
	checkedIdle := false
	if gate.prepare("installer", func() bool { checkedIdle = true; return true }) {
		t.Fatal("handoff cancelled in-flight work")
	}
	if checkedIdle {
		t.Fatal("must reject pending requests before inspecting runtime")
	}
	gate.endWork()
	if !gate.prepare("installer", func() bool { return true }) {
		t.Fatal("idle handoff refused")
	}
	if gate.beginWork() {
		t.Fatal("new work accepted after quiescence")
	}
	gate.release("another-client")
	if gate.beginWork() {
		t.Fatal("another client released the maintenance lease")
	}
	gate.release("installer")
	if !gate.beginWork() {
		t.Fatal("abandoned installation did not resume service")
	}
	gate.endWork()
}

func TestRegistrationHandoffRejectsActiveRuntimeOrSetup(t *testing.T) {
	for _, state := range []string{"connected", "connecting", "tailscale-setup", "unknown"} {
		t.Run(state, func(t *testing.T) {
			gate := &daemonRegistrationGate{}
			if gate.prepare("installer", func() bool { return false }) {
				t.Fatal("non-idle runtime was accepted")
			}
			if !gate.beginWork() {
				t.Fatal("busy refusal left the service quiesced")
			}
			gate.endWork()
		})
	}
}

func TestRegistrationHandoffAndNewWorkAreAtomic(t *testing.T) {
	for i := 0; i < 100; i++ {
		gate := &daemonRegistrationGate{}
		var group sync.WaitGroup
		var acceptedWork, acceptedHandoff bool
		group.Add(2)
		go func() {
			defer group.Done()
			acceptedWork = gate.beginWork()
		}()
		go func() {
			defer group.Done()
			acceptedHandoff = gate.prepare("installer", func() bool { return true })
		}()
		group.Wait()
		if acceptedWork == acceptedHandoff {
			t.Fatalf("exactly one side must win: work=%v handoff=%v", acceptedWork, acceptedHandoff)
		}
	}
}

func TestRegistrationHandoffOnlyExemptsReadOnlyDiagnostics(t *testing.T) {
	for _, command := range []string{"status", "daemon-info", "connection-report"} {
		if !registrationDiagnosticCommand(command) {
			t.Errorf("diagnostic command %q should remain available", command)
		}
	}
	for _, command := range []string{"start", "respawn", "parse-sub", "tailscale-status", "tailscale-login", "unknown"} {
		if registrationDiagnosticCommand(command) {
			t.Errorf("command %q bypasses quiescence", command)
		}
	}
}

func TestCommittedHandoffSurvivesInstallerExitAndCanBeAdopted(t *testing.T) {
	gate := &daemonRegistrationGate{}
	if !gate.prepare("first", func() bool { return true }) || !gate.commit("first") {
		t.Fatal("commit failed")
	}
	gate.release("first")
	if gate.beginWork() {
		t.Fatal("pending OS unregister can now kill newly accepted work")
	}
	if !gate.prepare("successor", func() bool { return true }) {
		t.Fatal("successor could not adopt abandoned commit")
	}
	if gate.abort("first", func() bool { return true }) {
		t.Fatal("old owner aborted successor")
	}
	gate.release("successor")
	if !gate.finalize(func() bool { return true }) || !gate.beginWork() {
		t.Fatal("verified finalization did not release maintenance")
	}
}

func TestColdStartAndExistingDaemonRejectWorkWithPersistentIntent(t *testing.T) {
	pending := false
	gate := &daemonRegistrationGate{intentPresent: func() bool { return pending }}
	if !gate.beginWork() {
		t.Fatal("normal work refused")
	}
	gate.endWork()
	pending = true
	if gate.beginWork() {
		t.Fatal("daemon ignored newly published intent")
	}
	cold := &daemonRegistrationGate{intentPresent: func() bool { return pending }}
	if cold.beginWork() {
		t.Fatal("KeepAlive successor ignored persistent intent")
	}
	if !cold.prepare("successor", func() bool { return true }) {
		t.Fatal("persistent intent prevented maintenance adoption")
	}
}

func TestFailedFinalizeKeepsCommittedDaemonQuiesced(t *testing.T) {
	gate := &daemonRegistrationGate{}
	gate.prepare("installer", func() bool { return true })
	gate.commit("installer")
	gate.release("installer")
	if gate.finalize(func() bool { return false }) {
		t.Fatal("failed verification became success")
	}
	if gate.beginWork() {
		t.Fatal("failed finalize released service")
	}
}

func TestRegistrationIntentFinalizeRequiresTokenPhaseAndExecutable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "maintenance")
	uid := uint32(os.Getuid())
	if err := os.WriteFile(path+".lock", nil, 0600); err != nil {
		t.Fatal(err)
	}
	expected := strings.Repeat("a", 64)
	write := func(phase string) {
		t.Helper()
		raw, _ := json.Marshal(registrationIntent{Version: 1, Token: "transaction", Phase: phase, TargetHash: expected})
		if err := os.WriteFile(path, raw, 0600); err != nil {
			t.Fatal(err)
		}
	}
	write("committed")
	if !registrationIntentPresent(path, uid) {
		t.Fatal("committed intent was ignored")
	}
	if finishRegistrationIntent(path, uid, "transaction", "registered", expected) {
		t.Fatal("unresolved OS transaction finalized")
	}
	write("registered")
	if finishRegistrationIntent(path, uid, "previous", "registered", expected) {
		t.Fatal("stale callback removed current transaction")
	}
	if finishRegistrationIntent(path, uid, "transaction", "registered", "old-executable") {
		t.Fatal("old daemon finalized new registration")
	}
	if !finishRegistrationIntent(path, uid, "transaction", "registered", expected) {
		t.Fatal("verified registration did not finalize")
	}
	if registrationIntentPresent(path, uid) {
		t.Fatal("finished intent remains active")
	}
}

func TestRegistrationIntentDoesNotFollowSymlinksOrTrustWrongOwner(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "intent")
	raw := filepath.Join(directory, "regular")
	if err := os.WriteFile(raw, []byte("partial private record"), 0600); err != nil {
		t.Fatal(err)
	}
	if !registrationIntentPresent(raw, uint32(os.Getuid())) {
		t.Fatal("partial private intent must fail closed")
	}
	if registrationIntentPresent(raw, uint32(os.Getuid()+1)) {
		t.Fatal("another user can quiesce this service")
	}
	if err := os.Symlink(raw, path); err != nil {
		t.Fatal(err)
	}
	if registrationIntentPresent(path, uint32(os.Getuid())) {
		t.Fatal("followed intent symlink")
	}
}

func TestRegistrationIntentReadSharesLockWithAtomicReplacement(t *testing.T) {
	path := filepath.Join(t.TempDir(), "maintenance")
	uid := uint32(os.Getuid())
	if err := os.WriteFile(path+".lock", nil, 0600); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(registrationIntent{Version: 1, Token: "transaction", Phase: "committed", TargetHash: strings.Repeat("a", 64)})
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	var group sync.WaitGroup
	errors := make(chan error, 3)
	group.Add(3)
	go func() {
		defer group.Done()
		for i := 0; i < 500; i++ {
			lock, err := lockRegistrationIntent(path, uid, syscall.LOCK_EX)
			if err != nil {
				errors <- err
				return
			}
			err = os.WriteFile(path+".candidate", raw, 0600)
			if err == nil {
				err = os.Rename(path+".candidate", path)
			}
			unlockRegistrationIntent(lock)
			if err != nil {
				errors <- err
				return
			}
		}
	}()
	for reader := 0; reader < 2; reader++ {
		go func() {
			defer group.Done()
			for i := 0; i < 1000; i++ {
				record, present := readRegistrationIntent(path, uid)
				if !present || record.Version != 1 || record.Token != "transaction" {
					errors <- fmt.Errorf("atomic replacement exposed absent or rejected snapshot: present=%v record=%+v", present, record)
					return
				}
			}
		}()
	}
	group.Wait()
	close(errors)
	for err := range errors {
		t.Error(err)
	}
}

func TestRegistrationIntentMissingOrUnsafeLockCannotReleaseOwnedMaintenance(t *testing.T) {
	path := filepath.Join(t.TempDir(), "maintenance")
	uid := uint32(os.Getuid())
	if registrationIntentPresent(path, uid) {
		t.Fatal("missing intent and lock should be absent")
	}
	if _, err := os.Lstat(path + ".lock"); !os.IsNotExist(err) {
		t.Fatal("root-side reader created a lock")
	}
	if err := os.WriteFile(path, []byte("private incomplete record"), 0600); err != nil {
		t.Fatal(err)
	}
	if !registrationIntentPresent(path, uid) {
		t.Fatal("missing lock released owned maintenance")
	}
	if err := os.WriteFile(path+".lock", nil, 0644); err != nil {
		t.Fatal(err)
	}
	if !registrationIntentPresent(path, uid) {
		t.Fatal("unsafe lock released owned maintenance")
	}
	if finishRegistrationIntent(path, uid, "transaction", "registered", "hash") {
		t.Fatal("unsafe lock authorized mutation")
	}
}
