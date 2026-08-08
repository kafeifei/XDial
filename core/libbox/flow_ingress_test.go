//go:build !windows

package libbox

import (
	"context"
	"io"
	"net"
	"strconv"
	"sync"
	"testing"
	"time"

	mDNS "github.com/miekg/dns"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing/common/buf"
	M "github.com/sagernet/sing/common/metadata"
)

// TestTransparentFlowCanEnterSingBoxRouter is an offline feasibility gate for
// the macOS flow-level ingress candidate. Apple owns the intercepted flow, but
// routing must still happen inside sing-box. Feeding a net.Conn plus its
// original destination into Router.RouteConnectionEx proves that no second
// XDial-side rule engine or TUN is required.
func TestTransparentFlowCanEnterSingBoxRouter(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen echo server: %v", err)
	}
	defer listener.Close()

	serverDone := make(chan error, 1)
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr != nil {
			serverDone <- acceptErr
			return
		}
		defer conn.Close()
		_, copyErr := io.Copy(conn, conn)
		serverDone <- copyErr
	}()

	runtime := newLoopbackFlowRuntime(t)
	defer runtime.Stop()

	appSide, ingressSide := net.Pipe()
	defer appSide.Close()

	destination := M.ParseSocksaddr(listener.Addr().String())
	closed := make(chan error, 1)
	runtime.box.Router().RouteConnectionEx(
		context.Background(),
		ingressSide,
		adapter.InboundContext{
			Inbound:     "macos-transparent-flow",
			InboundType: "transparent",
			Source:      M.SocksaddrFromNet(appSide.LocalAddr()),
			Destination: destination,
		},
		func(closeErr error) {
			select {
			case closed <- closeErr:
			default:
			}
		},
	)

	if err := appSide.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatalf("set flow deadline: %v", err)
	}
	const payload = "xdial-flow-ingress"
	if _, err := appSide.Write([]byte(payload)); err != nil {
		t.Fatalf("write intercepted flow: %v", err)
	}
	reply := make([]byte, len(payload))
	if _, err := io.ReadFull(appSide, reply); err != nil {
		t.Fatalf("read routed reply: %v", err)
	}
	if string(reply) != payload {
		t.Fatalf("unexpected routed reply %q", reply)
	}

	_ = appSide.Close()
	select {
	case <-closed:
	case <-time.After(5 * time.Second):
		t.Fatal("routed flow did not close")
	}
	select {
	case serverErr := <-serverDone:
		if serverErr != nil {
			t.Fatalf("echo server: %v", serverErr)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("echo server did not finish")
	}
}

func TestTransparentUDPFlowCanEnterSingBoxRouter(t *testing.T) {
	server, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen UDP echo server: %v", err)
	}
	defer server.Close()

	serverDone := make(chan error, 1)
	go func() {
		data := make([]byte, 2048)
		length, remote, readErr := server.ReadFrom(data)
		if readErr != nil {
			serverDone <- readErr
			return
		}
		_, writeErr := server.WriteTo(data[:length], remote)
		serverDone <- writeErr
	}()

	runtime := newLoopbackFlowRuntime(t)
	defer runtime.Stop()

	destination := M.ParseSocksaddr(server.LocalAddr().String())
	flow := newMemoryFlowPacketConn()
	const payload = "xdial-udp-flow-ingress"
	flow.incoming <- memoryFlowDatagram{
		payload:     []byte(payload),
		destination: destination,
	}

	closed := make(chan error, 1)
	runtime.box.Router().RoutePacketConnectionEx(
		context.Background(),
		flow,
		adapter.InboundContext{
			Inbound:     "macos-transparent-flow",
			InboundType: "transparent",
			Source:      M.ParseSocksaddr("127.0.0.1:40000"),
			Destination: destination,
		},
		func(closeErr error) {
			select {
			case closed <- closeErr:
			default:
			}
		},
	)

	select {
	case reply := <-flow.outgoing:
		if string(reply.payload) != payload {
			t.Fatalf("unexpected UDP reply %q", reply.payload)
		}
		if reply.destination != destination {
			t.Fatalf("unexpected UDP reply source %v, want %v", reply.destination, destination)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for routed UDP reply")
	}

	_ = flow.Close()
	select {
	case <-closed:
	case <-time.After(5 * time.Second):
		t.Fatal("routed UDP flow did not close")
	}
	select {
	case serverErr := <-serverDone:
		if serverErr != nil {
			t.Fatalf("UDP echo server: %v", serverErr)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("UDP echo server did not finish")
	}
}

func TestDNSProxyFlowUsesSingBoxDNSRouter(t *testing.T) {
	runtime := newLoopbackFlowRuntimeWithConfig(t, `{
		"log":{"disabled":true},
		"dns":{
			"servers":[{
				"type":"hosts",
				"tag":"controlled-dns",
				"predefined":{"flow.test":["192.0.2.10"]}
			}],
			"final":"controlled-dns"
		},
		"outbounds":[{"type":"direct","tag":"direct"}],
		"route":{
			"rules":[
				{"action":"sniff"},
				{"protocol":"dns","action":"hijack-dns"}
			],
			"final":"direct"
		}
	}`)
	defer runtime.Stop()

	query := new(mDNS.Msg)
	query.SetQuestion("flow.test.", mDNS.TypeA)
	queryData, err := query.Pack()
	if err != nil {
		t.Fatalf("pack DNS query: %v", err)
	}

	destination := M.ParseSocksaddr("192.0.2.53:53")
	flow := newMemoryFlowPacketConn()
	flow.incoming <- memoryFlowDatagram{
		payload:     queryData,
		destination: destination,
	}

	routeDone := make(chan struct{})
	go func() {
		defer close(routeDone)
		runtime.box.Router().RoutePacketConnectionEx(
			context.Background(),
			flow,
			adapter.InboundContext{
				Inbound:     "macos-dns-proxy-flow",
				InboundType: "dns-proxy",
				Source:      M.ParseSocksaddr("127.0.0.1:40001"),
				Destination: destination,
			},
			nil,
		)
	}()

	select {
	case reply := <-flow.outgoing:
		var response mDNS.Msg
		if err := response.Unpack(reply.payload); err != nil {
			t.Fatalf("unpack DNS response: %v", err)
		}
		if len(response.Answer) != 1 {
			t.Fatalf("unexpected DNS answer count %d: %v", len(response.Answer), response.Answer)
		}
		answer, ok := response.Answer[0].(*mDNS.A)
		if !ok || answer.A.String() != "192.0.2.10" {
			t.Fatalf("unexpected DNS answer %v", response.Answer[0])
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for sing-box DNS response")
	}
	_ = flow.Close()
	select {
	case <-routeDone:
	case <-time.After(5 * time.Second):
		t.Fatal("sing-box DNS route did not close")
	}
}

func newLoopbackFlowRuntime(t *testing.T) *Libbox {
	t.Helper()
	return newLoopbackFlowRuntimeWithConfig(t, `{
		"log":{"disabled":true},
		"outbounds":[{"type":"direct","tag":"direct"}],
		"route":{"final":"direct"}
	}`)
}

func newLoopbackFlowRuntimeWithConfig(t *testing.T, configJSON string) *Libbox {
	t.Helper()
	interfaces, err := net.Interfaces()
	if err != nil {
		t.Fatalf("list network interfaces: %v", err)
	}
	var loopback *net.Interface
	for index := range interfaces {
		candidate := &interfaces[index]
		if candidate.Flags&net.FlagLoopback != 0 && candidate.Flags&net.FlagUp != 0 {
			loopback = candidate
			break
		}
	}
	if loopback == nil {
		t.Fatal("find active loopback interface: no matching interface")
	}
	runtime := New(nil)
	runtime.SetDefaultInterface(loopback.Name, loopback.Index)
	if err := runtime.SetNetworkInterfaces(`[{"name":` + strconv.Quote(loopback.Name) + `,"index":` +
		strconv.Itoa(loopback.Index) + `,"type":"other"}]`); err != nil {
		t.Fatalf("set platform interfaces: %v", err)
	}
	if err := runtime.StartStandalone(configJSON); err != nil {
		t.Fatalf("start sing-box without a TUN inbound: %v", err)
	}
	return runtime
}

type memoryFlowDatagram struct {
	payload     []byte
	destination M.Socksaddr
}

type memoryFlowPacketConn struct {
	incoming  chan memoryFlowDatagram
	outgoing  chan memoryFlowDatagram
	closed    chan struct{}
	closeOnce sync.Once
}

func newMemoryFlowPacketConn() *memoryFlowPacketConn {
	return &memoryFlowPacketConn{
		incoming: make(chan memoryFlowDatagram, 1),
		outgoing: make(chan memoryFlowDatagram, 1),
		closed:   make(chan struct{}),
	}
}

func (c *memoryFlowPacketConn) ReadPacket(buffer *buf.Buffer) (M.Socksaddr, error) {
	select {
	case datagram := <-c.incoming:
		if _, err := buffer.Write(datagram.payload); err != nil {
			return M.Socksaddr{}, err
		}
		return datagram.destination, nil
	case <-c.closed:
		return M.Socksaddr{}, net.ErrClosed
	}
}

func (c *memoryFlowPacketConn) WritePacket(buffer *buf.Buffer, destination M.Socksaddr) error {
	defer buffer.Release()
	datagram := memoryFlowDatagram{
		payload:     append([]byte(nil), buffer.Bytes()...),
		destination: destination,
	}
	select {
	case c.outgoing <- datagram:
		return nil
	case <-c.closed:
		return net.ErrClosed
	}
}

func (c *memoryFlowPacketConn) Close() error {
	c.closeOnce.Do(func() {
		close(c.closed)
	})
	return nil
}

func (c *memoryFlowPacketConn) LocalAddr() net.Addr {
	return &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)}
}

func (c *memoryFlowPacketConn) SetDeadline(time.Time) error      { return nil }
func (c *memoryFlowPacketConn) SetReadDeadline(time.Time) error  { return nil }
func (c *memoryFlowPacketConn) SetWriteDeadline(time.Time) error { return nil }
