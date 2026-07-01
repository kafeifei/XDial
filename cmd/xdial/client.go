package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"time"
)

func dialDaemon(socketPath string) (net.Conn, error) {
	conn, err := net.DialTimeout("unix", socketPath, 3*time.Second)
	if err != nil {
		return nil, fmt.Errorf("cannot connect to daemon at %s (is it running?): %w", socketPath, err)
	}
	return conn, nil
}

// serverMessage is a union type for reading either Response or Event from the daemon.
type serverMessage struct {
	// Response fields
	ID      string `json:"id,omitempty"`
	OK      bool   `json:"ok,omitempty"`
	Message string `json:"message,omitempty"`
	Data    string `json:"data,omitempty"`

	// Event fields
	Event string `json:"event,omitempty"`
}

func (m *serverMessage) isResponse() bool { return m.ID != "" }
func (m *serverMessage) isEvent() bool    { return m.Event != "" }

// sendCommand sends a request and waits for the matching response,
// discarding any events received in the meantime.
func sendCommand(socketPath string, req Request) (*Response, error) {
	conn, err := dialDaemon(socketPath)
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	conn.SetDeadline(time.Now().Add(5 * time.Second))

	enc := json.NewEncoder(conn)
	if err := enc.Encode(req); err != nil {
		return nil, fmt.Errorf("send command: %w", err)
	}

	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 4*1024*1024), 4*1024*1024)
	for scanner.Scan() {
		var msg serverMessage
		if err := json.Unmarshal(scanner.Bytes(), &msg); err != nil {
			continue
		}
		if msg.isResponse() && msg.ID == req.ID {
			return &Response{
				ID:      msg.ID,
				OK:      msg.OK,
				Message: msg.Message,
				Data:    msg.Data,
			}, nil
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}
	return nil, fmt.Errorf("connection closed without response")
}
