package vpn

import (
	"bufio"
	"crypto/tls"
	"encoding/binary"
	"fmt"
	"io"
	"net/http"
	"time"

	"sslcon/base"
	"sslcon/proto"
	"sslcon/session"
)

// 复用已有的 tls.Conn 和对应的 bufR
func tlsChannel(conn *tls.Conn, bufR *bufio.Reader, cSess *session.ConnSession, resp *http.Response) {
	defer func() {
		base.Info("tls channel exit")
		resp.Body.Close()
		_ = conn.Close()
		cSess.Close()
	}()
	dead := time.Duration(cSess.TLSDpdTime+5) * time.Second

	go payloadOutTLSToServer(conn, cSess)

	// Step 21 serverToPayloadIn
	// 读取服务器返回的数据，调整格式，放入 cSess.PayloadIn
	for {
		// 重置超时限制
		if cSess.ResetTLSReadDead.Load() {
			_ = conn.SetReadDeadline(time.Now().Add(dead))
			cSess.ResetTLSReadDead.Store(false)
		}

		bytesReceived, keepRunning, readErr := readTLSPayload(bufR, cSess)
		if readErr != nil {
			base.Error("tls server to payloadIn error:", readErr)
			return
		}
		if !keepRunning {
			return
		}
		cSess.Stat.BytesReceived += uint64(bytesReceived)
	}
}

// readTLSPayload 读取并分派一个 CSTP 帧。只有成功写入数据通道时才移交缓冲
// 所有权；控制包、畸形包、读错误和关闭分支都在返回前归还缓冲池。
func readTLSPayload(reader io.Reader, cSess *session.ConnSession) (bytesReceived int, keepRunning bool, err error) {
	pl := getPayloadBuffer()
	transferred := false
	defer func() {
		if !transferred {
			putPayloadBuffer(pl)
		}
	}()

	headerSize := len(proto.Header)
	headerBytes, readErr := io.ReadFull(reader, pl.Data[:headerSize])
	bytesReceived = headerBytes
	if readErr != nil {
		return bytesReceived, false, readErr
	}
	dataLen := int(binary.BigEndian.Uint16(pl.Data[4:6]))
	if dataLen > len(pl.Data)-headerSize {
		return bytesReceived, false, fmt.Errorf("CSTP data frame exceeds buffer size")
	}
	payloadBytes, readErr := io.ReadFull(reader, pl.Data[headerSize:headerSize+dataLen])
	bytesReceived += payloadBytes
	err = readErr
	if err != nil {
		return bytesReceived, false, err
	}

	// https://datatracker.ietf.org/doc/html/draft-mavrogiannopoulos-openconnect-03#section-2.2
	switch pl.Data[6] {
	case 0x00: // DATA
		copy(pl.Data, pl.Data[headerSize:headerSize+dataLen])
		pl.Data = pl.Data[:dataLen]

		select {
		case cSess.PayloadIn <- pl:
			transferred = true
			return bytesReceived, true, nil
		case <-cSess.CloseChan:
			return bytesReceived, false, nil
		}
	case 0x04:
		base.Debug("tls receive DPD-RESP")
	case 0x03: // DPD-REQ
		pl.Type = 0x04
		select {
		case cSess.PayloadOutTLS <- pl:
			transferred = true
			return bytesReceived, true, nil
		case <-cSess.CloseChan:
			return bytesReceived, false, nil
		}
	case 0x07: // KEEPALIVE
		// 收到保活包，无需处理，读操作本身已重置超时。
	}
	return bytesReceived, true, nil
}

// payloadOutTLSToServer Step 4
func payloadOutTLSToServer(conn *tls.Conn, cSess *session.ConnSession) {
	defer func() {
		base.Info("tls payloadOut to server exit")
		_ = conn.Close()
		cSess.Close()
	}()

	var (
		err       error
		bytesSent int
		pl        *proto.Payload
	)

	for {
		select {
		case pl = <-cSess.PayloadOutTLS:
		case <-cSess.CloseChan:
			return
		}

		bytesSent, err = writeTLSPayload(conn, pl)
		if err != nil {
			base.Error("tls payloadOut to server error:", err)
			return
		}
		cSess.Stat.BytesSent += uint64(bytesSent)
	}
}

func writeTLSPayload(writer io.Writer, pl *proto.Payload) (bytesSent int, err error) {
	defer putPayloadBuffer(pl)
	if pl.Type == 0x00 {
		dataLen := len(pl.Data)
		if dataLen > cap(pl.Data)-len(proto.Header) {
			return 0, fmt.Errorf("CSTP payload has no header capacity")
		}
		pl.Data = pl.Data[:dataLen+len(proto.Header)]
		copy(pl.Data[len(proto.Header):], pl.Data)
		copy(pl.Data[:len(proto.Header)], proto.Header)
		binary.BigEndian.PutUint16(pl.Data[4:6], uint16(dataLen))
	} else {
		pl.Data = append(pl.Data[:0], proto.Header...)
		pl.Data[6] = pl.Type
	}
	return writer.Write(pl.Data)
}
