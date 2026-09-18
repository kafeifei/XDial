//go:build !windows

package libbox

import (
	"encoding/json"
	"fmt"
	"sort"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
	"github.com/sagernet/sing/service"
)

type lineLatencyFact struct {
	LineID         string `json:"line_id"`
	Milliseconds   *int   `json:"milliseconds,omitempty"`
	ObservedAt     int64  `json:"observed_at,omitempty"`
	SelectedLineID string `json:"selected_line_id,omitempty"`
}

// LineLatencySnapshot only reads sing-box's history and actual group selection.
// The Provider supplies its committed Go-generated capability map, never user tags.
func (l *Libbox) LineLatencySnapshot(lineOutboundsJSON string) (string, error) {
	var tags map[string]string
	if json.Unmarshal([]byte(lineOutboundsJSON), &tags) != nil || len(tags) > 10000 {
		return "", fmt.Errorf("invalid line catalog")
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.running || l.box == nil || l.runtimeCtx == nil || l.switchCommitInProgress {
		return "", fmt.Errorf("connection is not running")
	}
	history := service.PtrFromContext[urltest.HistoryStorage](l.runtimeCtx)
	ids := make([]string, 0, len(tags))
	for id := range tags {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	byTag := make(map[string]string, len(tags))
	for _, id := range ids {
		if byTag[tags[id]] == "" {
			byTag[tags[id]] = id
		}
	}
	facts := make([]lineLatencyFact, 0, len(ids))
	for _, id := range ids {
		outbound, found := l.box.Outbound().Outbound(tags[id])
		if !found {
			continue
		}
		fact := lineLatencyFact{LineID: id}
		seen := map[string]bool{}
		for depth := 0; depth < 32; depth++ {
			group, isGroup := outbound.(adapter.OutboundGroup)
			if !isGroup || seen[outbound.Tag()] {
				break
			}
			seen[outbound.Tag()] = true
			next, exists := l.box.Outbound().Outbound(group.Now())
			if !exists {
				break
			}
			outbound = next
			fact.SelectedLineID = byTag[outbound.Tag()]
		}
		if result := history.LoadURLTestHistory(outbound.Tag()); result != nil {
			delay := int(result.Delay)
			fact.Milliseconds, fact.ObservedAt = &delay, result.Time.UnixMilli()
		}
		facts = append(facts, fact)
	}
	encoded, err := json.Marshal(facts)
	return string(encoded), err
}
