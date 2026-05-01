package engine

import "time"

type Status int

const (
	StatusDisconnected Status = iota
	StatusConnecting
	StatusConnected
	StatusDisconnecting
)

func (s Status) String() string {
	switch s {
	case StatusDisconnected:
		return "disconnected"
	case StatusConnecting:
		return "connecting"
	case StatusConnected:
		return "connected"
	case StatusDisconnecting:
		return "disconnecting"
	default:
		return "unknown"
	}
}

type StatusMessage struct {
	Status      string `json:"status"`
	Mode        string `json:"mode,omitempty"`
	ConnectedAt int64  `json:"connected_at,omitempty"`
	UpBytes     int64  `json:"up_bytes,omitempty"`
	DownBytes   int64  `json:"down_bytes,omitempty"`
	Error       string `json:"error,omitempty"`
}

type StatusCallback interface {
	OnStatusChanged(statusJSON string)
	OnError(code int, message string)
}

func newStatusMessage(s Status) StatusMessage {
	msg := StatusMessage{Status: s.String()}
	if s == StatusConnected {
		msg.ConnectedAt = time.Now().Unix()
	}
	return msg
}
