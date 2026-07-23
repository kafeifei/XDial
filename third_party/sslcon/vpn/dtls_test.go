package vpn

import (
	"bytes"
	"io"
	"testing"

	"sslcon/base"
	"sslcon/proto"
	"sslcon/session"
)

func newDTLSTestSessions(buffered bool) (*session.DtlsSession, *session.ConnSession) {
	capacity := 0
	if buffered {
		capacity = 1
	}
	dSess := &session.DtlsSession{CloseChan: make(chan struct{})}
	cSess := &session.ConnSession{
		PayloadIn:      make(chan *proto.Payload, capacity),
		PayloadOutDTLS: make(chan *proto.Payload, capacity),
	}
	return dSess, cSess
}

func TestReadDTLSPayloadTransfersDataOwnership(t *testing.T) {
	testPool := installDeterministicPayloadPool(t)
	dSess, cSess := newDTLSTestSessions(true)

	bytesReceived, keepRunning, err := readDTLSPayload(bytes.NewReader([]byte{0x00, 0x45}), dSess, cSess)
	if err != nil || !keepRunning || bytesReceived != 2 {
		t.Fatalf("readDTLSPayload = (%d, %t, %v)", bytesReceived, keepRunning, err)
	}
	if testPool.puts != 0 {
		t.Fatalf("transferred data buffer returned %d times before consumption", testPool.puts)
	}
	payload := <-cSess.PayloadIn
	if len(payload.Data) != 1 || payload.Data[0] != 0x45 {
		t.Fatalf("unexpected transferred payload: %x", payload.Data)
	}
	ReleasePayloadBuffer(payload)
	if testPool.puts != 1 {
		t.Fatalf("consumed data buffer returned %d times, want 1", testPool.puts)
	}
}

func TestReadDTLSPayloadTransfersDPDResponseOwnership(t *testing.T) {
	testPool := installDeterministicPayloadPool(t)
	dSess, cSess := newDTLSTestSessions(true)

	_, keepRunning, err := readDTLSPayload(bytes.NewReader([]byte{0x03}), dSess, cSess)
	if err != nil || !keepRunning {
		t.Fatalf("readDTLSPayload = (_, %t, %v)", keepRunning, err)
	}
	if testPool.puts != 0 {
		t.Fatalf("transferred DPD buffer returned %d times before consumption", testPool.puts)
	}
	payload := <-cSess.PayloadOutDTLS
	if payload.Type != 0x04 {
		t.Fatalf("DPD response type = %#x, want 0x04", payload.Type)
	}
	ReleasePayloadBuffer(payload)
}

func TestReadDTLSPayloadReturnsUntransferredBuffers(t *testing.T) {
	base.InitLog()
	for _, payloadType := range []byte{0x04, 0x05, 0x07, 0xff} {
		t.Run(string([]byte{payloadType}), func(t *testing.T) {
			testPool := installDeterministicPayloadPool(t)
			dSess, cSess := newDTLSTestSessions(true)
			_, keepRunning, err := readDTLSPayload(bytes.NewReader([]byte{payloadType}), dSess, cSess)
			if err != nil {
				t.Fatalf("readDTLSPayload: %v", err)
			}
			wantRunning := payloadType != 0x05
			if keepRunning != wantRunning {
				t.Fatalf("keepRunning = %t, want %t", keepRunning, wantRunning)
			}
			if testPool.puts != 1 {
				t.Fatalf("control buffer returned %d times, want 1", testPool.puts)
			}
		})
	}

	t.Run("closed", func(t *testing.T) {
		testPool := installDeterministicPayloadPool(t)
		dSess, cSess := newDTLSTestSessions(false)
		close(dSess.CloseChan)
		_, keepRunning, err := readDTLSPayload(bytes.NewReader([]byte{0x00, 1}), dSess, cSess)
		if err != nil || keepRunning {
			t.Fatalf("readDTLSPayload = (_, %t, %v)", keepRunning, err)
		}
		if testPool.puts != 1 {
			t.Fatalf("closed-session buffer returned %d times, want 1", testPool.puts)
		}
	})
}

func TestReadDTLSPayloadReturnsBufferOnReadOrFrameError(t *testing.T) {
	for _, testCase := range []struct {
		name   string
		reader io.Reader
	}{
		{name: "read", reader: bytes.NewReader(nil)},
		{name: "empty", reader: zeroPayloadReader{}},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			testPool := installDeterministicPayloadPool(t)
			dSess, cSess := newDTLSTestSessions(true)
			_, keepRunning, err := readDTLSPayload(testCase.reader, dSess, cSess)
			if err == nil || keepRunning {
				t.Fatalf("readDTLSPayload = (_, %t, %v), want stopping error", keepRunning, err)
			}
			if testPool.puts != 1 {
				t.Fatalf("failed-read buffer returned %d times, want 1", testPool.puts)
			}
		})
	}
}

type zeroPayloadReader struct{}

func (zeroPayloadReader) Read([]byte) (int, error) {
	return 0, nil
}

func TestWriteDTLSPayloadReturnsBufferOnWriteError(t *testing.T) {
	testPool := installDeterministicPayloadPool(t)
	payload := getPayloadBuffer()
	payload.Data = payload.Data[:1]
	payload.Data[0] = 0x45

	if _, err := writeDTLSPayload(failingPayloadWriter{}, payload); err == nil {
		t.Fatal("expected write error")
	}
	if testPool.puts != 1 {
		t.Fatalf("failed-write buffer returned %d times, want 1", testPool.puts)
	}
}

func TestWriteDTLSPayloadReturnsBufferWithoutHeaderCapacity(t *testing.T) {
	testPool := installDeterministicPayloadPool(t)
	payload := getPayloadBuffer()

	if _, err := writeDTLSPayload(&bytes.Buffer{}, payload); err == nil {
		t.Fatal("expected header-capacity error")
	}
	if testPool.puts != 1 {
		t.Fatalf("oversized buffer returned %d times, want 1", testPool.puts)
	}
}

func TestWriteDTLSPayloadPreservesWireFormat(t *testing.T) {
	testPool := installDeterministicPayloadPool(t)
	payload := getPayloadBuffer()
	payload.Data = payload.Data[:1]
	payload.Data[0] = 0x45
	var wire bytes.Buffer

	bytesSent, err := writeDTLSPayload(&wire, payload)
	want := []byte{0x00, 0x45}
	if err != nil || bytesSent != len(want) || !bytes.Equal(wire.Bytes(), want) {
		t.Fatalf("writeDTLSPayload sent %x (%d, %v), want %x", wire.Bytes(), bytesSent, err, want)
	}
	if testPool.puts != 1 {
		t.Fatalf("successful-write buffer returned %d times, want 1", testPool.puts)
	}
}
