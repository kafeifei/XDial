package engine

import (
	"context"
	"testing"
	"time"

	"sslcon/proto"
	"sslcon/session"
)

func TestNewVPNBridgeRejectsIPv6Address(t *testing.T) {
	if _, err := NewVPNBridge("2001:db8::1", 1400); err == nil {
		t.Fatal("NewVPNBridge accepted an IPv6 tunnel address")
	}
}

func TestVPNBridgeDialTCPRejectsIPv6Destination(t *testing.T) {
	bridge, err := NewVPNBridge("10.0.0.2", 1400)
	if err != nil {
		t.Fatalf("NewVPNBridge: %v", err)
	}
	defer bridge.Close()

	if _, err := bridge.DialTCP(context.Background(), "[2001:db8::1]:443"); err == nil {
		t.Fatal("DialTCP accepted an IPv6 destination")
	}
}

func TestVPNBridgeReleasesEveryConsumedInboundPayload(t *testing.T) {
	bridge, err := NewVPNBridge("10.0.0.2", 1400)
	if err != nil {
		t.Fatalf("NewVPNBridge: %v", err)
	}
	defer bridge.Close()

	released := make(chan *proto.Payload, 3)
	bridge.releaseIn = func(payload *proto.Payload) {
		released <- payload
	}
	sess := &session.ConnSession{
		CloseChan: make(chan struct{}),
		PayloadIn: make(chan *proto.Payload, 3),
	}
	go bridge.vpnToStack(sess)
	defer close(sess.CloseChan)

	invalid := &proto.Payload{Type: 0x07, Data: []byte{1}}
	empty := &proto.Payload{Type: 0x00}
	validBranch := &proto.Payload{Type: 0x00, Data: []byte{0x45}}
	sess.PayloadIn <- invalid
	sess.PayloadIn <- empty
	sess.PayloadIn <- validBranch

	for index, want := range []*proto.Payload{invalid, empty, validBranch} {
		select {
		case got := <-released:
			if got != want {
				t.Fatalf("release %d got %p, want %p", index, got, want)
			}
		case <-time.After(time.Second):
			t.Fatalf("timed out waiting for release %d", index)
		}
	}
	if got := len(released); got != 0 {
		t.Fatalf("received %d extra releases", got)
	}
	if stats := bridge.Stats(); stats.DownPackets != 1 || stats.DownBytes != 1 {
		t.Fatalf("downstream stats = %+v, want 1 packet and 1 byte", stats)
	}
}

func TestVPNBridgeStopsWhenPayloadInIsClosed(t *testing.T) {
	bridge, err := NewVPNBridge("10.0.0.2", 1400)
	if err != nil {
		t.Fatalf("NewVPNBridge: %v", err)
	}
	defer bridge.Close()

	sess := &session.ConnSession{
		CloseChan: make(chan struct{}),
		PayloadIn: make(chan *proto.Payload),
	}
	close(sess.PayloadIn)

	done := make(chan struct{})
	go func() {
		bridge.vpnToStack(sess)
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("vpnToStack did not stop after PayloadIn closed")
	}
}
