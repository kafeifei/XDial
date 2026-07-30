package main

import (
	"bufio"
	"encoding/json"
	"net"
	"sync"
	"sync/atomic"
)

// Request is a command from client to daemon.
type Request struct {
	ID         string `json:"id"`
	Cmd        string `json:"cmd"`
	Profile    string `json:"profile,omitempty"`
	SubURL     string `json:"sub_url,omitempty"`
	SubContent string `json:"sub_content,omitempty"`
	SubFormat  string `json:"sub_format,omitempty"`
	LineID     string `json:"line_id,omitempty"`
	AuthKey    string `json:"auth_key,omitempty"`
}

// Response is a direct reply to a Request (carries the same ID).
type Response struct {
	ID      string `json:"id"`
	OK      bool   `json:"ok"`
	Message string `json:"message,omitempty"`
	Data    string `json:"data,omitempty"`
}

// Event is a daemon-initiated push (status change, error).
type Event struct {
	Event string `json:"event"`
	Data  string `json:"data,omitempty"`
}

var requestSeq atomic.Uint64

func nextRequestID() string {
	n := requestSeq.Add(1)
	buf := make([]byte, 0, 8)
	for n > 0 {
		buf = append(buf, byte('0'+n%10))
		n /= 10
	}
	for i, j := 0, len(buf)-1; i < j; i, j = i+1, j-1 {
		buf[i], buf[j] = buf[j], buf[i]
	}
	return string(buf)
}

// Client represents one connected client.
type Client struct {
	conn net.Conn
	enc  *json.Encoder
	mu   sync.Mutex
}

func NewClient(conn net.Conn) *Client {
	return &Client{conn: conn, enc: json.NewEncoder(conn)}
}

func (c *Client) SendResponse(r Response) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.enc.Encode(r)
}

func (c *Client) SendEvent(e Event) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.enc.Encode(e)
}

func (c *Client) Close() { c.conn.Close() }

// ReadRequests reads newline-delimited JSON requests from conn.
func ReadRequests(conn net.Conn, ch chan<- Request) {
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 4*1024*1024), 4*1024*1024)
	for scanner.Scan() {
		var req Request
		if err := json.Unmarshal(scanner.Bytes(), &req); err != nil {
			continue
		}
		ch <- req
	}
	close(ch)
}

// ClientSet manages connected clients.
type ClientSet struct {
	mu      sync.Mutex
	clients map[*Client]struct{}
}

func NewClientSet() *ClientSet {
	return &ClientSet{clients: make(map[*Client]struct{})}
}

func (cs *ClientSet) Add(c *Client) {
	cs.mu.Lock()
	cs.clients[c] = struct{}{}
	cs.mu.Unlock()
}

func (cs *ClientSet) Remove(c *Client) {
	cs.mu.Lock()
	delete(cs.clients, c)
	cs.mu.Unlock()
}

func (cs *ClientSet) BroadcastEvent(e Event) {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	for c := range cs.clients {
		c.SendEvent(e)
	}
}
