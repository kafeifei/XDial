package main

import (
	"bufio"
	"encoding/json"
	"io"
	"net"
	"sync"
)

type Request struct {
	Cmd        string `json:"cmd"`
	Profile    string `json:"profile,omitempty"`
	SubURL     string `json:"sub_url,omitempty"`
	SubContent string `json:"sub_content,omitempty"`
	SubFormat  string `json:"sub_format,omitempty"`
}

type Response struct {
	Type    string `json:"type"`
	Cmd     string `json:"cmd,omitempty"`
	OK      bool   `json:"ok,omitempty"`
	Message string `json:"message,omitempty"`
	Data    string `json:"data,omitempty"`
}

type Client struct {
	conn    net.Conn
	encoder *json.Encoder
	mu      sync.Mutex
}

func NewClient(conn net.Conn) *Client {
	return &Client{
		conn:    conn,
		encoder: json.NewEncoder(conn),
	}
}

func (c *Client) Send(resp Response) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.encoder.Encode(resp)
}

func (c *Client) Close() {
	c.conn.Close()
}

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

func (cs *ClientSet) Broadcast(resp Response) {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	for c := range cs.clients {
		if err := c.Send(resp); err != nil {
			continue
		}
	}
}

func drainConn(conn net.Conn) {
	io.Copy(io.Discard, conn)
}
