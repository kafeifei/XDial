package vpn

import (
	"testing"

	"sslcon/proto"
)

type deterministicPayloadPool struct {
	items []interface{}
	new   func() interface{}
	puts  int
}

func installDeterministicPayloadPool(t *testing.T) *deterministicPayloadPool {
	t.Helper()
	originalPool := pool
	testPool := &deterministicPayloadPool{
		new: func() interface{} {
			return &proto.Payload{Data: make([]byte, BufferSize)}
		},
	}
	pool = testPool
	t.Cleanup(func() { pool = originalPool })
	return testPool
}

func (p *deterministicPayloadPool) Get() interface{} {
	last := len(p.items) - 1
	if last < 0 {
		return p.new()
	}
	item := p.items[last]
	p.items = p.items[:last]
	return item
}

func (p *deterministicPayloadPool) Put(item interface{}) {
	p.puts++
	p.items = append(p.items, item)
}

func TestReleasePayloadBufferResetsAndReusesPayload(t *testing.T) {
	testPool := installDeterministicPayloadPool(t)

	payload := getPayloadBuffer()
	payload.Type = 0x07
	payload.Data = payload.Data[:23]

	ReleasePayloadBuffer(payload)
	if testPool.puts != 1 {
		t.Fatalf("release count = %d, want 1", testPool.puts)
	}

	reused := getPayloadBuffer()
	if reused != payload {
		t.Fatal("released payload was not returned by the pool")
	}
	if reused.Type != 0x00 {
		t.Fatalf("reused payload type = %#x, want 0", reused.Type)
	}
	if len(reused.Data) != BufferSize || cap(reused.Data) != BufferSize {
		t.Fatalf("reused data len/cap = %d/%d, want %d/%d",
			len(reused.Data), cap(reused.Data), BufferSize, BufferSize)
	}

	ReleasePayloadBuffer(nil)
	if testPool.puts != 1 {
		t.Fatalf("nil release changed count to %d", testPool.puts)
	}
}

func TestReleasePayloadBufferDoesNotPoolExpandedPayload(t *testing.T) {
	testPool := installDeterministicPayloadPool(t)

	ReleasePayloadBuffer(&proto.Payload{Data: make([]byte, BufferSize+1)})
	if testPool.puts != 0 {
		t.Fatalf("expanded payload was added to fixed-size pool")
	}
}
