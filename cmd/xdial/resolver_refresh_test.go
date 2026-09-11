package main

import (
	"errors"
	"testing"
	"time"
)

func newTestResolverRefresher(now *time.Time, signalled *[]int, findErr, signalErr error) *resolverRefresher {
	return &resolverRefresher{
		now: func() time.Time { return *now },
		findPID: func() (int, error) {
			if findErr != nil {
				return 0, findErr
			}
			return 42, nil
		},
		sendHUP: func(pid int) error {
			if signalErr != nil {
				return signalErr
			}
			*signalled = append(*signalled, pid)
			return nil
		},
		interval: resolverRefreshMinInterval,
	}
}

func TestResolverRefreshSignalsLocatedProcess(t *testing.T) {
	now := time.Unix(1000, 0)
	var signalled []int
	refresher := newTestResolverRefresher(&now, &signalled, nil, nil)

	ok, message := refresher.refresh("transaction-committed")
	if !ok || message != "" {
		t.Fatalf("refresh must succeed: ok=%v message=%q", ok, message)
	}
	if len(signalled) != 1 || signalled[0] != 42 {
		t.Fatalf("expected one SIGHUP to pid 42, got %v", signalled)
	}
}

func TestResolverRefreshCoalescesBurst(t *testing.T) {
	now := time.Unix(1000, 0)
	var signalled []int
	refresher := newTestResolverRefresher(&now, &signalled, nil, nil)

	for _, trigger := range []string{"transaction-committed", "proxy-stopped", "host-launch"} {
		if ok, _ := refresher.refresh(trigger); !ok {
			t.Fatalf("%s must be accepted", trigger)
		}
		now = now.Add(100 * time.Millisecond)
	}
	if len(signalled) != 1 {
		t.Fatalf("a burst of transitions must send one SIGHUP, got %d", len(signalled))
	}

	now = now.Add(resolverRefreshMinInterval)
	if ok, _ := refresher.refresh("proxy-stopped"); !ok {
		t.Fatal("refresh after the interval must be accepted")
	}
	if len(signalled) != 2 {
		t.Fatalf("a later transition must send its own SIGHUP, got %d", len(signalled))
	}
}

func TestResolverRefreshReportsMissingProcess(t *testing.T) {
	now := time.Unix(1000, 0)
	var signalled []int
	refresher := newTestResolverRefresher(&now, &signalled, errors.New("mDNSResponder is not running"), nil)

	ok, message := refresher.refresh("host-launch")
	if ok {
		t.Fatal("a failed lookup must not report success")
	}
	if message == "" {
		t.Fatal("failure must carry a reason")
	}
	if len(signalled) != 0 {
		t.Fatalf("nothing may be signalled, got %v", signalled)
	}
}

// 失败不能顶替"上一次刷新"，否则一次 pgrep 抖动会把紧随其后的真实机会也吞掉。
func TestResolverRefreshFailureDoesNotSuppressNextAttempt(t *testing.T) {
	now := time.Unix(1000, 0)
	var signalled []int
	refresher := newTestResolverRefresher(&now, &signalled, nil, errors.New("no such process"))

	if ok, _ := refresher.refresh("transaction-committed"); ok {
		t.Fatal("a failed signal must not report success")
	}

	refresher.sendHUP = func(pid int) error {
		signalled = append(signalled, pid)
		return nil
	}
	now = now.Add(10 * time.Millisecond)
	if ok, message := refresher.refresh("transaction-committed"); !ok || message != "" {
		t.Fatalf("retry must succeed: ok=%v message=%q", ok, message)
	}
	if len(signalled) != 1 {
		t.Fatalf("expected the retry to send SIGHUP, got %v", signalled)
	}
}
