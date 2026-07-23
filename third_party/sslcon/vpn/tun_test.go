package vpn

import (
	"errors"
	"testing"

	"go.uber.org/atomic"
	"sslcon/proto"
	"sslcon/session"
)

type tunPacketReaderFunc func([]byte, int) (int, error)

func (f tunPacketReaderFunc) Read(buffer []byte, offset int) (int, error) {
	return f(buffer, offset)
}

type tunPacketWriterFunc func([]byte, int) (int, error)

func (f tunPacketWriterFunc) Write(buffer []byte, offset int) (int, error) {
	return f(buffer, offset)
}

func useTUNOffset(t *testing.T, value int) {
	t.Helper()
	original := offset
	offset = value
	t.Cleanup(func() { offset = original })
}

func newTUNTestSession(dtlsConnected, buffered bool) *session.ConnSession {
	capacity := 0
	if buffered {
		capacity = 1
	}
	return &session.ConnSession{
		CloseChan:      make(chan struct{}),
		PayloadOutTLS:  make(chan *proto.Payload, capacity),
		PayloadOutDTLS: make(chan *proto.Payload, capacity),
		DtlsConnected:  atomic.NewBool(dtlsConnected),
		DSess:          &session.DtlsSession{CloseChan: make(chan struct{})},
	}
}

func TestReadTUNPayloadTransfersNormalizedBufferOwnership(t *testing.T) {
	testPool := installDeterministicPayloadPool(t)
	useTUNOffset(t, 4)
	sess := newTUNTestSession(false, true)
	reader := tunPacketReaderFunc(func(buffer []byte, gotOffset int) (int, error) {
		if gotOffset != 4 {
			t.Fatalf("read offset = %d, want 4", gotOffset)
		}
		buffer[gotOffset] = 0x45
		return 1, nil
	})

	keepRunning, err := readTUNPayload(reader, sess)
	if err != nil || !keepRunning {
		t.Fatalf("readTUNPayload = (%t, %v)", keepRunning, err)
	}
	if testPool.puts != 0 {
		t.Fatalf("transferred buffer returned %d times before consumption", testPool.puts)
	}
	payload := <-sess.PayloadOutTLS
	if len(payload.Data) != 1 || cap(payload.Data) != BufferSize || payload.Data[0] != 0x45 {
		t.Fatalf("normalized payload len/cap/data = %d/%d/%x", len(payload.Data), cap(payload.Data), payload.Data)
	}
	ReleasePayloadBuffer(payload)
	if testPool.puts != 1 {
		t.Fatalf("consumed buffer returned %d times, want 1", testPool.puts)
	}
}

func TestReadTUNPayloadReturnsBufferOnReadError(t *testing.T) {
	testPool := installDeterministicPayloadPool(t)
	useTUNOffset(t, 0)
	sess := newTUNTestSession(false, true)
	reader := tunPacketReaderFunc(func([]byte, int) (int, error) {
		return 0, errors.New("read failed")
	})

	if keepRunning, err := readTUNPayload(reader, sess); err == nil || keepRunning {
		t.Fatalf("readTUNPayload = (%t, %v), want stopping error", keepRunning, err)
	}
	if testPool.puts != 1 {
		t.Fatalf("failed-read buffer returned %d times, want 1", testPool.puts)
	}
}

func TestReadTUNPayloadReturnsBufferWhenOutputCloses(t *testing.T) {
	for _, dtlsConnected := range []bool{false, true} {
		t.Run(map[bool]string{false: "tls", true: "dtls"}[dtlsConnected], func(t *testing.T) {
			testPool := installDeterministicPayloadPool(t)
			useTUNOffset(t, 0)
			sess := newTUNTestSession(dtlsConnected, false)
			if dtlsConnected {
				close(sess.DSess.CloseChan)
			} else {
				close(sess.CloseChan)
			}
			reader := tunPacketReaderFunc(func(buffer []byte, _ int) (int, error) {
				buffer[0] = 0x45
				return 1, nil
			})

			keepRunning, err := readTUNPayload(reader, sess)
			wantRunning := dtlsConnected
			if err != nil || keepRunning != wantRunning {
				t.Fatalf("readTUNPayload = (%t, %v)", keepRunning, err)
			}
			if dtlsConnected && sess.DtlsConnected.Load() {
				t.Fatal("closed DTLS output did not fall back to TLS")
			}
			if testPool.puts != 1 {
				t.Fatalf("closed-output buffer returned %d times, want 1", testPool.puts)
			}
		})
	}
}

func TestWriteTUNPayloadReturnsBufferOnWriteError(t *testing.T) {
	testPool := installDeterministicPayloadPool(t)
	useTUNOffset(t, 4)
	payload := getPayloadBuffer()
	payload.Data = payload.Data[:1]
	payload.Data[0] = 0x45
	writer := tunPacketWriterFunc(func(buffer []byte, gotOffset int) (int, error) {
		if gotOffset != 4 || len(buffer) != 5 || buffer[4] != 0x45 {
			t.Fatalf("write buffer offset/data = %d/%x", gotOffset, buffer)
		}
		return 0, errors.New("write failed")
	})

	if _, err := writeTUNPayload(writer, payload); err == nil {
		t.Fatal("expected write error")
	}
	if testPool.puts != 1 {
		t.Fatalf("failed-write buffer returned %d times, want 1", testPool.puts)
	}
}
