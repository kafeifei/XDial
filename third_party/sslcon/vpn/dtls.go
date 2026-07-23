package vpn

import (
	"context"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"strconv"
	"time"

	"github.com/pion/dtls/v3"
	"sslcon/base"
	"sslcon/proto"
	"sslcon/session"
)

// 新建 dtls.Conn
func dtlsChannel(cSess *session.ConnSession) {
	var (
		conn  *dtls.Conn
		dSess *session.DtlsSession
		err   error
		dead  = time.Duration(cSess.DTLSDpdTime+5) * time.Second
	)
	defer func() {
		base.Info("dtls channel exit")
		if conn != nil {
			_ = conn.Close()
		}
		if dSess != nil {
			dSess.Close()
		}
	}()

	port, _ := strconv.Atoi(cSess.DTLSPort)
	addr := &net.UDPAddr{IP: net.ParseIP(cSess.ServerAddress), Port: port}

	id, _ := hex.DecodeString(cSess.DTLSId)

	config := &dtls.Config{
		InsecureSkipVerify:   true,
		ExtendedMasterSecret: dtls.DisableExtendedMasterSecret,
		CipherSuites: func() []dtls.CipherSuiteID {
			switch cSess.DTLSCipherSuite {
			case "ECDHE-ECDSA-AES128-GCM-SHA256":
				return []dtls.CipherSuiteID{dtls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256}
			case "ECDHE-RSA-AES128-GCM-SHA256":
				return []dtls.CipherSuiteID{dtls.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256}
			case "ECDHE-ECDSA-AES256-GCM-SHA384":
				return []dtls.CipherSuiteID{dtls.TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384}
			case "ECDHE-RSA-AES256-GCM-SHA384":
				return []dtls.CipherSuiteID{dtls.TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384}
			default:
				return []dtls.CipherSuiteID{dtls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256}
			}
		}(),
		SessionStore: &SessionStore{dtls.Session{ID: id, Secret: session.Sess.PreMasterSecret}},
		// PSK: func(hint []byte) ([]byte, error) {
		//     // return []byte{0xAB, 0xC1, 0x23}, nil
		//     return id, nil
		// },
		// PSKIdentityHint: id,
	}

	conn, err = dtls.Dial("udp4", addr, config)
	// https://github.com/pion/dtls/pull/649
	if err != nil {
		base.Error(err)
		close(cSess.DtlsSetupChan) // 没有成功建立 DTLS 隧道
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err = conn.HandshakeContext(ctx); err != nil {
		base.Error(err)
		close(cSess.DtlsSetupChan) // 没有成功建立 DTLS 隧道
		return
	}

	cSess.DtlsConnected.Store(true)
	dSess = cSess.DSess
	close(cSess.DtlsSetupChan) // 成功建立 DTLS 隧道

	// rewrite cSess.DTLSCipherSuite
	state, success := conn.ConnectionState()
	if success {
		cSess.DTLSCipherSuite = dtls.CipherSuiteName(state.CipherSuiteID)
	} else {
		cSess.DTLSCipherSuite = ""
	}

	base.Info("dtls channel negotiation succeeded")

	go payloadOutDTLSToServer(conn, dSess, cSess)

	// Step 21 serverToPayloadIn
	// 读取服务器返回的数据，调整格式，放入 cSess.PayloadIn，不再用子协程是为了能够退出 dtlsChannel 协程
	for {
		// 重置超时限制
		if cSess.ResetDTLSReadDead.Load() {
			_ = conn.SetReadDeadline(time.Now().Add(dead))
			cSess.ResetDTLSReadDead.Store(false)
		}

		bytesReceived, keepRunning, readErr := readDTLSPayload(conn, dSess, cSess)
		if readErr != nil {
			base.Error("dtls server to payloadIn error:", readErr)
			return
		}
		if !keepRunning {
			return
		}
		cSess.Stat.BytesReceived += uint64(bytesReceived)
	}
}

// readDTLSPayload 读取并分派一个 DTLS 数据报。只有成功写入数据通道时才移交
// 缓冲所有权；其余路径统一在返回前归还缓冲池。
func readDTLSPayload(reader io.Reader, dSess *session.DtlsSession, cSess *session.ConnSession) (bytesReceived int, keepRunning bool, err error) {
	pl := getPayloadBuffer()
	transferred := false
	defer func() {
		if !transferred {
			putPayloadBuffer(pl)
		}
	}()

	bytesReceived, err = reader.Read(pl.Data)
	if err != nil {
		return 0, false, err
	}
	if bytesReceived < 1 {
		return bytesReceived, false, fmt.Errorf("empty DTLS payload")
	}

	// https://datatracker.ietf.org/doc/html/draft-mavrogiannopoulos-openconnect-02#section-2.3
	// UDP 数据包的头部只有 1 字节。
	switch pl.Data[0] {
	case 0x07: // KEEPALIVE
	case 0x05: // DISCONNECT
		return bytesReceived, false, nil
	case 0x03: // DPD-REQ
		pl.Type = 0x04
		select {
		case cSess.PayloadOutDTLS <- pl:
			transferred = true
			return bytesReceived, true, nil
		case <-dSess.CloseChan:
			return bytesReceived, false, nil
		}
	case 0x04:
		base.Debug("dtls receive DPD-RESP")
	case 0x00: // DATA
		copy(pl.Data, pl.Data[1:bytesReceived])
		pl.Data = pl.Data[:bytesReceived-1]
		select {
		case cSess.PayloadIn <- pl:
			transferred = true
			return bytesReceived, true, nil
		case <-dSess.CloseChan:
			return bytesReceived, false, nil
		}
	}
	return bytesReceived, true, nil
}

// payloadOutDTLSToServer Step 4
func payloadOutDTLSToServer(conn *dtls.Conn, dSess *session.DtlsSession, cSess *session.ConnSession) {
	defer func() {
		base.Info("dtls payloadOut to server exit")
		_ = conn.Close()
		dSess.Close()
	}()

	var (
		err       error
		bytesSent int
		pl        *proto.Payload
	)

	for {
		select {
		case pl = <-cSess.PayloadOutDTLS:
		case <-dSess.CloseChan:
			return
		}

		bytesSent, err = writeDTLSPayload(conn, pl)
		if err != nil {
			base.Error("dtls payloadOut to server error:", err)
			return
		}
		cSess.Stat.BytesSent += uint64(bytesSent)
	}
}

func writeDTLSPayload(writer io.Writer, pl *proto.Payload) (bytesSent int, err error) {
	defer putPayloadBuffer(pl)
	if pl.Type == 0x00 {
		dataLen := len(pl.Data)
		if dataLen >= cap(pl.Data) {
			return 0, fmt.Errorf("DTLS payload has no header capacity")
		}
		pl.Data = pl.Data[:dataLen+1]
		copy(pl.Data[1:], pl.Data)
		pl.Data[0] = pl.Type
	} else {
		pl.Data = append(pl.Data[:0], pl.Type)
	}
	return writer.Write(pl.Data)
}

type SessionStore struct {
	sess dtls.Session
}

func (store *SessionStore) Set([]byte, dtls.Session) error {
	return nil
}

func (store *SessionStore) Get([]byte) (dtls.Session, error) {
	return store.sess, nil
}

func (store *SessionStore) Del([]byte) error {
	return nil
}
