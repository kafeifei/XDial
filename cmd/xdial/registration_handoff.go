package main

import (
	"encoding/json"
	"os"
	"sync"
	"syscall"
)

const registrationIntentPath = "/tmp/xdial-registration-maintenance"

type registrationIntent struct {
	Version    int    `json:"version"`
	Token      string `json:"token"`
	TargetHash string `json:"target_hash"`
	Phase      string `json:"phase"`
}

// Readers share Swift's stable lock so rename cannot detach the inode between
// open and fstat. Unknown lock/file state is maintenance, never permission to
// accept work. Only a confirmed missing intent is absent.
func readRegistrationIntent(path string, expectedUID uint32) (registrationIntent, bool) {
	lock, err := lockRegistrationIntent(path, expectedUID, syscall.LOCK_SH)
	if err != nil {
		if untrustedRegistrationIntent(path, expectedUID) {
			return registrationIntent{}, false
		}
		if os.IsNotExist(err) {
			if _, statErr := os.Lstat(path); os.IsNotExist(statErr) {
				return registrationIntent{}, false
			}
		}
		return registrationIntent{}, true
	}
	defer unlockRegistrationIntent(lock)
	return readRegistrationIntentUnlocked(path, expectedUID)
}

func readRegistrationIntentUnlocked(path string, expectedUID uint32) (registrationIntent, bool) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		if untrustedRegistrationIntent(path, expectedUID) {
			return registrationIntent{}, false
		}
		return registrationIntent{}, !os.IsNotExist(err)
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return registrationIntent{}, true
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if ok && (!info.Mode().IsRegular() || stat.Uid != expectedUID) {
		return registrationIntent{}, false
	}
	if !ok || info.Mode().Perm() != 0600 || stat.Nlink != 1 {
		return registrationIntent{}, true
	}
	var intent registrationIntent
	_ = json.NewDecoder(f).Decode(&intent)
	return intent, true
}

func untrustedRegistrationIntent(path string, expectedUID uint32) bool {
	info, err := os.Lstat(path)
	if err != nil {
		return false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && (!info.Mode().IsRegular() || stat.Uid != expectedUID)
}

func lockRegistrationIntent(path string, uid uint32, operation int) (*os.File, error) {
	// Root only opens the existing user-owned lock; it must not create one that
	// prevents the unprivileged installer from adopting an unfinished operation.
	lock, err := os.OpenFile(path+".lock", os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	info, err := lock.Stat()
	if err != nil {
		lock.Close()
		return nil, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.Mode().IsRegular() || info.Mode().Perm() != 0600 || stat.Uid != uid || stat.Nlink != 1 {
		lock.Close()
		return nil, syscall.EPERM
	}
	for {
		err = syscall.Flock(int(lock.Fd()), operation)
		if err != syscall.EINTR {
			break
		}
	}
	if err != nil {
		lock.Close()
		return nil, err
	}
	return lock, nil
}

func unlockRegistrationIntent(lock *os.File) {
	_ = syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	_ = lock.Close()
}

func registrationIntentPresent(path string, expectedUID uint32) bool {
	_, present := readRegistrationIntent(path, expectedUID)
	return present
}

func registrationConsoleUID() (uint32, bool) {
	info, err := os.Stat("/dev/console")
	if err != nil {
		return 0, false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, false
	}
	return stat.Uid, true
}

func currentRegistrationIntentPresent() bool {
	uid, ok := registrationConsoleUID()
	if !ok {
		return true
	}
	return registrationIntentPresent(registrationIntentPath, uid)
}

func finishRegistrationIntent(path string, uid uint32, token, phase, executableHash string) bool {
	lock, err := lockRegistrationIntent(path, uid, syscall.LOCK_EX)
	if err != nil {
		return false
	}
	defer unlockRegistrationIntent(lock)
	intent, present := readRegistrationIntentUnlocked(path, uid)
	if !present || intent.Version != 1 || intent.Token != token || token == "" ||
		intent.Phase != phase || (executableHash != "" && intent.TargetHash != executableHash) {
		return false
	}
	return os.Remove(path) == nil
}

// Prepare is connection-scoped. Commit survives loss of the installer socket:
// an already submitted OS unregister may still complete after that loss.
type daemonRegistrationGate struct {
	mu            sync.Mutex
	activeWork    int
	owner         string
	committed     bool
	intentPresent func() bool
}

func (g *daemonRegistrationGate) beginWork() bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.owner != "" || g.committed || (g.intentPresent != nil && g.intentPresent()) {
		return false
	}
	g.activeWork++
	return true
}
func (g *daemonRegistrationGate) endWork() { g.mu.Lock(); defer g.mu.Unlock(); g.activeWork-- }
func (g *daemonRegistrationGate) prepare(owner string, isIdle func() bool) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if owner == "" || g.owner != "" || g.activeWork != 0 || !isIdle() {
		return false
	}
	g.owner = owner
	return true
}
func (g *daemonRegistrationGate) commit(owner string) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if owner == "" || g.owner != owner {
		return false
	}
	g.committed = true
	return true
}
func (g *daemonRegistrationGate) abort(owner string, finish func() bool) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if owner == "" || g.owner != owner || !finish() {
		return false
	}
	g.committed = false
	g.owner = ""
	return true
}
func (g *daemonRegistrationGate) finalize(finish func() bool) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.owner != "" || !finish() {
		return false
	}
	g.committed = false
	return true
}
func (g *daemonRegistrationGate) release(owner string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.owner == owner {
		g.owner = ""
	}
}
func registrationDiagnosticCommand(command string) bool {
	switch command {
	case "status", "daemon-info", "connection-report":
		return true
	default:
		return false
	}
}
