//go:build !windows

package libbox

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"time"

	"github.com/kafeifei/xdial/core/config"
	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing-box/protocol/group"
	jsonext "github.com/sagernet/sing/common/json"
	"github.com/sagernet/sing/service"
)

func validLatencyTestURL(target string) bool {
	u, err := url.Parse(target)
	return err == nil && (u.Scheme == "https" || u.Scheme == "http") && u.Hostname() != "" && u.User == nil
}

// TestLineLatency accepts only committed outbound capabilities. A group supplies
// its native test URL; callers cannot provide an arbitrary runtime test address.
func (l *Libbox) TestLineLatency(outboundTag, groupTag string, timeoutMS int) (int, error) {
	target := lineLatencyTestURL
	l.mu.Lock()
	if !l.running || l.box == nil || l.switchCommitInProgress {
		l.mu.Unlock()
		return 0, fmt.Errorf("connection is not running")
	}
	if groupTag != "" {
		parent, exists := l.box.Outbound().Outbound(groupTag)
		if !exists || !nativeGroupContains(l.box, parent, outboundTag, map[string]bool{}) {
			l.mu.Unlock()
			return 0, fmt.Errorf("group capability is unavailable")
		}
		if automatic, ok := parent.(*group.URLTest); ok && automatic.TestURL() != "" {
			target = automatic.TestURL()
		}
	}
	l.mu.Unlock()
	return l.TestOutbound(outboundTag, target, timeoutMS)
}

func nativeGroupContains(instance *box.Box, root adapter.Outbound, tag string, seen map[string]bool) bool {
	if seen[root.Tag()] {
		return false
	}
	seen[root.Tag()] = true
	if root.Tag() == tag {
		return true
	}
	if members, ok := root.(adapter.OutboundGroup); ok {
		for _, childTag := range members.All() {
			if child, exists := instance.Outbound().Outbound(childTag); exists && nativeGroupContains(instance, child, tag, seen) {
				return true
			}
		}
	}
	return false
}

// Children update before parents so nested groups expose the native actual exit.
// This never calls SelectOutbound, changes a Profile, or starts network requests.
func refreshNativeGroupSelections(instance *box.Box) {
	seen := map[string]bool{}
	var visit func(adapter.Outbound)
	visit = func(outbound adapter.Outbound) {
		if seen[outbound.Tag()] {
			return
		}
		seen[outbound.Tag()] = true
		if members, ok := outbound.(adapter.OutboundGroup); ok {
			for _, tag := range members.All() {
				if child, exists := instance.Outbound().Outbound(tag); exists {
					visit(child)
				}
			}
		}
		if automatic, ok := outbound.(*group.URLTest); ok {
			automatic.RefreshSelection()
		}
	}
	for _, outbound := range instance.Outbound().Outbounds() {
		visit(outbound)
	}
}

// EvaluateLineGroupLatencies is a data-only preview of sing-box's selection.
// The temporary Box has no ingress, credentials, DNS servers, system integration,
// or PostStart timers. Leaf placeholders are NEVER dialed: only their tags and
// real, successful measurement history are used by native selectors/urltests.
// No preview choice is persisted or claimed to be the active network exit.
func EvaluateLineGroupLatencies(linesJSON, factsJSON string) (string, error) {
	var lines []config.Line
	var facts []lineLatencyFact
	if len(linesJSON) > 4*1024*1024 || len(factsJSON) > 4*1024*1024 || json.Unmarshal([]byte(linesJSON), &lines) != nil || json.Unmarshal([]byte(factsJSON), &facts) != nil || len(lines) > 10000 {
		return "", fmt.Errorf("invalid latency catalog")
	}
	outbounds := make([]map[string]interface{}, 0, len(lines))
	tags := map[string]string{}
	catalog := map[string]config.Line{}
	for _, line := range lines {
		if _, exists := catalog[line.ID]; line.ID == "" || exists {
			return "", fmt.Errorf("invalid latency catalog")
		}
		catalog[line.ID] = line
	}
	// Incomplete draft groups do not suppress results for other valid groups.
	state := map[string]int{}
	var usable func(string, int) bool
	usable = func(id string, depth int) bool {
		if state[id] != 0 {
			return state[id] == 2
		}
		line, found := catalog[id]
		if !found || depth > 32 {
			return false
		}
		state[id] = 1
		if line.Type == config.LineTypeSelector || line.Type == config.LineTypeURLTest {
			if len(line.GroupMembers) == 0 {
				return false
			}
			defaultExists := line.GroupDefault == "" || line.Type != config.LineTypeSelector
			for _, member := range line.GroupMembers {
				if !usable(member, depth+1) {
					return false
				}
				if member == line.GroupDefault {
					defaultExists = true
				}
			}
			if !defaultExists {
				return false
			}
		}
		state[id] = 2
		return true
	}
	for _, line := range lines {
		if !usable(line.ID, 0) {
			continue
		}
		tags[line.ID] = line.ID
		value := map[string]interface{}{"type": "direct", "tag": line.ID}
		if line.Type == config.LineTypeSelector || line.Type == config.LineTypeURLTest {
			value["type"] = string(line.Type)
			value["outbounds"] = line.GroupMembers
			if line.Type == config.LineTypeSelector && line.GroupDefault != "" {
				value["default"] = line.GroupDefault
			}
		}
		outbounds = append(outbounds, value)
	}
	if len(outbounds) == 0 {
		return "[]", nil
	}
	ctx := boxContext(context.Background())
	raw, _ := json.Marshal(map[string]interface{}{"log": map[string]interface{}{"disabled": true}, "outbounds": outbounds})
	opts, err := jsonext.UnmarshalExtendedContext[option.Options](ctx, raw)
	if err != nil {
		return "", err
	}
	instance, err := box.New(box.Options{Options: opts, Context: ctx})
	if err != nil {
		return "", err
	}
	defer instance.Close()
	// Starting only the outbound manager initializes native group membership.
	// In particular, URLTest.PostStart must never run in this data-only preview.
	if err = instance.Outbound().Start(adapter.StartStateStart); err != nil {
		return "", err
	}
	history := service.PtrFromContext[urltest.HistoryStorage](ctx)
	for _, fact := range facts {
		if tags[fact.LineID] != "" && fact.Milliseconds != nil && *fact.Milliseconds >= 0 && *fact.Milliseconds <= 65535 && fact.ObservedAt > 0 {
			history.StoreURLTestHistory(fact.LineID, &adapter.URLTestHistory{Time: time.UnixMilli(fact.ObservedAt), Delay: uint16(*fact.Milliseconds)})
		}
	}
	refreshNativeGroupSelections(instance)
	runtime := &Libbox{box: instance, runtimeCtx: ctx, running: true}
	catalogJSON, _ := json.Marshal(tags)
	return runtime.LineLatencySnapshot(string(catalogJSON))
}
