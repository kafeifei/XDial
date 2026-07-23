package vpn

import (
	"bytes"
	"encoding/binary"
	"errors"
	"testing"

	"sslcon/base"
	"sslcon/proto"
	"sslcon/session"
)

func newTLSTestSession(buffered bool) *session.ConnSession {
	capacity := 0
	if buffered {
		capacity = 1
	}
	return &session.ConnSession{
		CloseChan:     make(chan struct{}),
		PayloadIn:     make(chan *proto.Payload, capacity),
		PayloadOutTLS: make(chan *proto.Payload, capacity),
	}
}

func tlsTestFrame(payloadType byte, data []byte) []byte {
	frame := append([]byte(nil), proto.Header...)
	frame[6] = payloadType
	binary.BigEndian.PutUint16(frame[4:6], uint16(len(data)))
	return append(frame, data...)
}

func TestReadTLSPayloadTransfersDataOwnership(t *testing.T) {
	testPool := installDeterministicPayloadPool(t)
	sess := newTLSTestSession(true)

	frame := tlsTestFrame(0x00, []byte{0x45})
	bytesReceived, keepRunning, err := readTLSPayload(bytes.NewReader(frame), sess)
	if err != nil || !keepRunning || bytesReceived != len(frame) {
		t.Fatalf("readTLSPayload = (%d, %t, %v)", bytesReceived, keepRunning, err)
	}
	if testPool.puts != 0 {
		t.Fatalf("transferred data buffer returned %d times before consumption", testPool.puts)
	}
	payload := <-sess.PayloadIn
	if len(payload.Data) != 1 || payload.Data[0] != 0x45 {
		t.Fatalf("unexpected transferred payload: %x", payload.Data)
	}
	ReleasePayloadBuffer(payload)
	if testPool.puts != 1 {
		t.Fatalf("consumed data buffer returned %d times, want 1", testPool.puts)
	}
}

func TestReadTLSPayloadTransfersDPDResponseOwnership(t *testing.T) {
	testPool := installDeterministicPayloadPool(t)
	sess := newTLSTestSession(true)

	_, keepRunning, err := readTLSPayload(bytes.NewReader(tlsTestFrame(0x03, nil)), sess)
	if err != nil || !keepRunning {
		t.Fatalf("readTLSPayload = (_, %t, %v)", keepRunning, err)
	}
	if testPool.puts != 0 {
		t.Fatalf("transferred DPD buffer returned %d times before consumption", testPool.puts)
	}
	payload := <-sess.PayloadOutTLS
	if payload.Type != 0x04 {
		t.Fatalf("DPD response type = %#x, want 0x04", payload.Type)
	}
	ReleasePayloadBuffer(payload)
}

func TestReadTLSPayloadReturnsUntransferredBuffers(t *testing.T) {
	base.InitLog()
	for _, payloadType := range []byte{0x04, 0x07, 0xff} {
		t.Run(string([]byte{payloadType}), func(t *testing.T) {
			testPool := installDeterministicPayloadPool(t)
			sess := newTLSTestSession(true)
			_, keepRunning, err := readTLSPayload(bytes.NewReader(tlsTestFrame(payloadType, nil)), sess)
			if err != nil || !keepRunning {
				t.Fatalf("readTLSPayload = (_, %t, %v)", keepRunning, err)
			}
			if testPool.puts != 1 {
				t.Fatalf("control buffer returned %d times, want 1", testPool.puts)
			}
		})
	}

	t.Run("closed", func(t *testing.T) {
		testPool := installDeterministicPayloadPool(t)
		sess := newTLSTestSession(false)
		close(sess.CloseChan)
		_, keepRunning, err := readTLSPayload(bytes.NewReader(tlsTestFrame(0x00, []byte{1})), sess)
		if err != nil || keepRunning {
			t.Fatalf("readTLSPayload = (_, %t, %v)", keepRunning, err)
		}
		if testPool.puts != 1 {
			t.Fatalf("closed-session buffer returned %d times, want 1", testPool.puts)
		}
	})
}

func TestReadTLSPayloadReturnsBufferOnReadOrFrameError(t *testing.T) {
	for _, testCase := range []struct {
		name  string
		frame []byte
	}{
		{name: "read", frame: nil},
		{name: "short", frame: []byte{1, 2, 3}},
		{name: "truncated", frame: tlsTestFrame(0x00, []byte{1})[:len(proto.Header)]},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			testPool := installDeterministicPayloadPool(t)
			sess := newTLSTestSession(true)
			_, keepRunning, err := readTLSPayload(bytes.NewReader(testCase.frame), sess)
			if err == nil || keepRunning {
				t.Fatalf("readTLSPayload = (_, %t, %v), want stopping error", keepRunning, err)
			}
			if testPool.puts != 1 {
				t.Fatalf("failed-read buffer returned %d times, want 1", testPool.puts)
			}
		})
	}
}

func TestReadTLSPayloadConsumesExactlyOneStreamFrame(t *testing.T) {
	testPool := installDeterministicPayloadPool(t)
	sess := newTLSTestSession(true)
	first := tlsTestFrame(0x07, nil)
	second := tlsTestFrame(0x00, []byte{0x45})
	reader := bytes.NewReader(append(first, second...))

	bytesReceived, keepRunning, err := readTLSPayload(reader, sess)
	if err != nil || !keepRunning || bytesReceived != len(first) {
		t.Fatalf("first read = (%d, %t, %v)", bytesReceived, keepRunning, err)
	}
	if reader.Len() != len(second) || testPool.puts != 1 {
		t.Fatalf("first read consumed %d extra bytes or returned %d buffers", len(second)-reader.Len(), testPool.puts)
	}

	bytesReceived, keepRunning, err = readTLSPayload(reader, sess)
	if err != nil || !keepRunning || bytesReceived != len(second) {
		t.Fatalf("second read = (%d, %t, %v)", bytesReceived, keepRunning, err)
	}
	ReleasePayloadBuffer(<-sess.PayloadIn)
	if testPool.puts != 2 {
		t.Fatalf("two frames returned %d buffers, want 2", testPool.puts)
	}
}

type failingPayloadWriter struct{}

func (failingPayloadWriter) Write([]byte) (int, error) {
	return 0, errors.New("write failed")
}

func TestWriteTLSPayloadReturnsBufferOnWriteError(t *testing.T) {
	testPool := installDeterministicPayloadPool(t)
	payload := getPayloadBuffer()
	payload.Data = payload.Data[:1]
	payload.Data[0] = 0x45

	if _, err := writeTLSPayload(failingPayloadWriter{}, payload); err == nil {
		t.Fatal("expected write error")
	}
	if testPool.puts != 1 {
		t.Fatalf("failed-write buffer returned %d times, want 1", testPool.puts)
	}
}

func TestWriteTLSPayloadReturnsBufferWithoutHeaderCapacity(t *testing.T) {
	testPool := installDeterministicPayloadPool(t)
	payload := getPayloadBuffer()

	if _, err := writeTLSPayload(&bytes.Buffer{}, payload); err == nil {
		t.Fatal("expected header-capacity error")
	}
	if testPool.puts != 1 {
		t.Fatalf("oversized buffer returned %d times, want 1", testPool.puts)
	}
}

func TestWriteTLSPayloadPreservesWireFormat(t *testing.T) {
	testPool := installDeterministicPayloadPool(t)
	payload := getPayloadBuffer()
	payload.Data = payload.Data[:1]
	payload.Data[0] = 0x45
	var wire bytes.Buffer

	bytesSent, err := writeTLSPayload(&wire, payload)
	want := tlsTestFrame(0x00, []byte{0x45})
	if err != nil || bytesSent != len(want) || !bytes.Equal(wire.Bytes(), want) {
		t.Fatalf("writeTLSPayload sent %x (%d, %v), want %x", wire.Bytes(), bytesSent, err, want)
	}
	if testPool.puts != 1 {
		t.Fatalf("successful-write buffer returned %d times, want 1", testPool.puts)
	}
}
