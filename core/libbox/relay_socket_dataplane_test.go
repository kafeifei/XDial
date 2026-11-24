//go:build !windows

package libbox

import (
	"bytes"
	"encoding/json"
	"io"
	"net"
	"os"
	"testing"
	"time"
)

// These tests drive a real sing-box data plane through the relay socket the
// way the macOS Provider does: SOCKS5 with the session credentials, every byte
// in a frame, and no loopback port anywhere between the two.

const (
	relayFrameData byte = 0x01
	relayFrameFin  byte = 0x02
)

type relaySocketClient struct {
	t    *testing.T
	conn *net.UnixConn
	rest []byte
}

func startRelaySocketDataPlane(t *testing.T) string {
	t.Helper()
	path := testRelaySocketPath(t)
	configJSON, err := json.Marshal(map[string]any{
		"log": map[string]any{"disabled": true},
		"inbounds": []any{map[string]any{
			"type":                "socks",
			"tag":                 "transparent-proxy-in",
			"xdial_relay_socket":  path,
			"xdial_flow_metadata": true,
			"users": []any{map[string]any{
				"username": "session-user",
				"password": "session-password",
			}},
		}},
		"outbounds": []any{map[string]any{"type": "direct", "tag": "direct"}},
		"route":     map[string]any{"final": "direct"},
	})
	if err != nil {
		t.Fatal(err)
	}
	runtime := newLoopbackFlowRuntimeWithConfig(t, string(configJSON))
	t.Cleanup(func() {
		_ = runtime.Stop()
		if _, statErr := os.Lstat(path); !os.IsNotExist(statErr) {
			t.Errorf("stopping the data plane left its relay socket behind: %v", statErr)
		}
	})
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatalf("relay socket was not created: %v", err)
	}
	if info.Mode()&os.ModeSocket == 0 || info.Mode().Perm() != 0o600 {
		t.Fatalf("relay socket mode = %v, want an owner-only socket", info.Mode())
	}
	return path
}

func dialRelaySocket(t *testing.T, path string) *relaySocketClient {
	t.Helper()
	conn, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatalf("dial relay socket: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	client := &relaySocketClient{t: t, conn: conn}
	client.send(5, 1, 2)
	if reply := client.receive(2); !bytes.Equal(reply, []byte{5, 2}) {
		t.Fatalf("method reply = %v", reply)
	}
	request := append([]byte{1, byte(len("session-user"))}, "session-user"...)
	request = append(request, byte(len("session-password")))
	request = append(request, "session-password"...)
	client.send(request...)
	if reply := client.receive(2); !bytes.Equal(reply, []byte{1, 0}) {
		t.Fatalf("authentication reply = %v", reply)
	}
	return client
}

func (c *relaySocketClient) sendFrame(frameType byte, payload []byte) {
	c.t.Helper()
	frame := []byte{frameType, byte(len(payload) >> 16), byte(len(payload) >> 8), byte(len(payload))}
	if _, err := c.conn.Write(append(frame, payload...)); err != nil {
		c.t.Fatalf("write relay frame: %v", err)
	}
}

// send writes a byte stream as DATA frames no larger than the Provider's.
func (c *relaySocketClient) send(payload ...byte) {
	c.t.Helper()
	const chunk = 32 << 10
	for len(payload) > chunk {
		c.sendFrame(relayFrameData, payload[:chunk])
		payload = payload[chunk:]
	}
	c.sendFrame(relayFrameData, payload)
}

// readFrame returns the next frame, or io.EOF when the stream ended without
// one — which on the relay socket means it was cut.
func (c *relaySocketClient) readFrame() (byte, []byte, error) {
	var header [4]byte
	if _, err := io.ReadFull(c.conn, header[:]); err != nil {
		return 0, nil, err
	}
	payload := make([]byte, int(header[1])<<16|int(header[2])<<8|int(header[3]))
	if _, err := io.ReadFull(c.conn, payload); err != nil {
		return 0, nil, err
	}
	return header[0], payload, nil
}

func (c *relaySocketClient) receive(length int) []byte {
	c.t.Helper()
	for len(c.rest) < length {
		frameType, payload, err := c.readFrame()
		if err != nil || frameType != relayFrameData {
			c.t.Fatalf("read relay data frame: type=%d err=%v", frameType, err)
		}
		c.rest = append(c.rest, payload...)
	}
	received := c.rest[:length]
	c.rest = c.rest[length:]
	return received
}

func (c *relaySocketClient) connect(target *net.TCPAddr) {
	c.t.Helper()
	ip := target.IP.To4()
	c.send(5, 1, 0, 1, ip[0], ip[1], ip[2], ip[3], byte(target.Port>>8), byte(target.Port))
	if reply := c.receive(10); reply[1] != 0 {
		c.t.Fatalf("connect reply = %v", reply)
	}
}

func listenRelayTestTCP(t *testing.T, serve func(conn *net.TCPConn)) *net.TCPAddr {
	t.Helper()
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	go func() {
		for {
			conn, err := listener.AcceptTCP()
			if err != nil {
				return
			}
			go serve(conn)
		}
	}()
	return listener.Addr().(*net.TCPAddr)
}

func TestRelaySocketCarriesTCPAndReportsACleanFinish(t *testing.T) {
	origin := listenRelayTestTCP(t, func(conn *net.TCPConn) {
		defer conn.Close()
		_, _ = io.Copy(conn, conn)
	})
	client := dialRelaySocket(t, startRelaySocketDataPlane(t))
	client.connect(origin)

	payload := bytes.Repeat([]byte("xdial-relay-socket"), 8192)
	go client.send(payload...)
	if got := client.receive(len(payload)); !bytes.Equal(got, payload) {
		t.Fatal("echoed bytes differ from the bytes sent")
	}

	// The application finished sending; the origin answers by finishing too.
	client.sendFrame(relayFrameFin, nil)
	frameType, _, err := client.readFrame()
	if err != nil || frameType != relayFrameFin {
		t.Fatalf("a finished exchange must end with a FIN frame: type=%d err=%v", frameType, err)
	}
}

func TestRelaySocketReportsAnUpstreamResetAsACutStream(t *testing.T) {
	origin := listenRelayTestTCP(t, func(conn *net.TCPConn) {
		_, _ = io.ReadFull(conn, make([]byte, 4))
		_, _ = conn.Write([]byte("half"))
		_ = conn.SetLinger(0)
		_ = conn.Close()
	})
	client := dialRelaySocket(t, startRelaySocketDataPlane(t))
	client.connect(origin)
	client.send([]byte("ping")...)

	// Whatever the origin sent before the reset may or may not arrive; what
	// matters is how the stream ends.
	for {
		frameType, _, err := client.readFrame()
		if err == io.EOF {
			return
		}
		if err != nil {
			t.Fatalf("read after upstream reset: %v", err)
		}
		if frameType == relayFrameFin {
			t.Fatal("an upstream reset was reported to the application as a clean finish")
		}
	}
}

func TestRelaySocketClosesTheUpstreamWhenTheApplicationIsCut(t *testing.T) {
	upstreamEnded := make(chan struct{})
	origin := listenRelayTestTCP(t, func(conn *net.TCPConn) {
		defer conn.Close()
		_, _ = io.Copy(io.Discard, conn)
		close(upstreamEnded)
	})
	client := dialRelaySocket(t, startRelaySocketDataPlane(t))
	client.connect(origin)
	client.send([]byte("ping")...)

	// The Provider cancels the connection without a FIN frame when the
	// application's flow fails. The upstream must not be left waiting.
	_ = client.conn.Close()
	select {
	case <-upstreamEnded:
	case <-time.After(5 * time.Second):
		t.Fatal("the upstream connection outlived a cut application flow")
	}
}

func TestRelaySocketCarriesUDPWithoutARelayPort(t *testing.T) {
	echo, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		buffer := make([]byte, 2048)
		for {
			length, remote, readErr := echo.ReadFromUDP(buffer)
			if readErr != nil {
				return
			}
			_, _ = echo.WriteToUDP(buffer[:length], remote)
		}
	}()
	target := echo.LocalAddr().(*net.UDPAddr)

	client := dialRelaySocket(t, startRelaySocketDataPlane(t))
	client.send(5, 3, 0, 1, 0, 0, 0, 0, 0, 0)
	reply := client.receive(10)
	if !bytes.Equal(reply, []byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0}) {
		t.Fatalf("UDP ASSOCIATE announced a relay endpoint: %v", reply)
	}

	ip := target.IP.To4()
	header := []byte{0, 0, 0, 1, ip[0], ip[1], ip[2], ip[3], byte(target.Port >> 8), byte(target.Port)}
	for _, payload := range []string{"first datagram", "second datagram"} {
		client.send(append(append([]byte(nil), header...), payload...)...)
		frameType, datagram, err := client.readFrame()
		if err != nil || frameType != relayFrameData {
			t.Fatalf("read echoed datagram: type=%d err=%v", frameType, err)
		}
		if !bytes.Equal(datagram, append(append([]byte(nil), header...), payload...)) {
			t.Fatalf("echoed datagram = %q", datagram)
		}
	}
}

func TestRelaySocketKeepsTheSessionCredentials(t *testing.T) {
	path := startRelaySocketDataPlane(t)
	conn, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	client := &relaySocketClient{t: t, conn: conn}
	// A client offering only "no authentication" is turned away.
	client.send(5, 1, 0)
	if reply := client.receive(2); !bytes.Equal(reply, []byte{5, 0xff}) {
		t.Fatalf("unauthenticated greeting was answered with %v", reply)
	}
}
