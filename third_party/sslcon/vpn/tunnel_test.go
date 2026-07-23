package vpn

import (
	"bufio"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"sslcon/auth"
	"sslcon/base"
	"sslcon/proto"
	"sslcon/session"
)

func TestSetupTunnelTimesOutWritingConnectRequest(t *testing.T) {
	client, server := tunnelTLSPipe(t)
	restore := installTunnelTestConnection(t, client)
	defer restore()

	go func() {
		time.Sleep(120 * time.Millisecond)
		_, _ = io.Copy(io.Discard, server)
	}()

	if err := auth.BeginHandshake(80 * time.Millisecond); err != nil {
		t.Fatalf("BeginHandshake() error = %v", err)
	}
	err := SetupTunnel()

	assertTunnelHandshakeTimeout(t, err, "CONNECT request write")
	assertNoTunnelSecrets(t, err)
}

func TestSetupTunnelTimesOutWhenServerDoesNotRespond(t *testing.T) {
	client, server := tunnelTLSPipe(t)
	restore := installTunnelTestConnection(t, client)
	defer restore()

	requestRead := make(chan struct{})
	go func() {
		_, _ = http.ReadRequest(bufio.NewReader(server))
		close(requestRead)
		time.Sleep(120 * time.Millisecond)
		_, _ = io.Copy(io.Discard, server)
	}()

	if err := auth.BeginHandshake(80 * time.Millisecond); err != nil {
		t.Fatalf("BeginHandshake() error = %v", err)
	}
	err := SetupTunnel()
	<-requestRead

	assertTunnelHandshakeTimeout(t, err, "CONNECT response")
	assertNoTunnelSecrets(t, err)
}

func TestSetupTunnelTimesOutWhenServerRespondsLate(t *testing.T) {
	client, server := tunnelTLSPipe(t)
	restore := installTunnelTestConnection(t, client)
	defer restore()

	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		_, _ = http.ReadRequest(bufio.NewReader(server))
		time.Sleep(160 * time.Millisecond)
		drained := make(chan struct{})
		go func() {
			_, _ = io.Copy(io.Discard, server)
			close(drained)
		}()
		_, _ = server.Write([]byte("HTTP/1.1 200 OK\r\n\r\n"))
		<-drained
	}()

	if err := auth.BeginHandshake(80 * time.Millisecond); err != nil {
		t.Fatalf("BeginHandshake() error = %v", err)
	}
	err := SetupTunnel()
	<-serverDone

	assertTunnelHandshakeTimeout(t, err, "CONNECT response")
	assertNoTunnelSecrets(t, err)
}

func TestSetupTunnelReplacesHandshakeDeadlineWithDataChannelDeadline(t *testing.T) {
	client, server := tunnelTLSPipe(t)
	restore := installTunnelTestConnection(t, client)
	defer restore()

	serverDone := make(chan error, 1)
	go func() {
		req, err := http.ReadRequest(bufio.NewReader(server))
		if err != nil {
			serverDone <- err
			return
		}
		if req.Method != http.MethodConnect {
			serverDone <- fmt.Errorf("method = %s", req.Method)
			return
		}
		if _, err = server.Write([]byte("HTTP/1.1 200 OK\r\nX-CSTP-Address: 10.0.0.2\r\nX-CSTP-Netmask: 255.255.255.0\r\nX-CSTP-MTU: 1399\r\nX-CSTP-DPD: 2\r\n\r\n")); err != nil {
			serverDone <- err
			return
		}

		time.Sleep(160 * time.Millisecond)
		frame := append([]byte(nil), proto.Header...)
		frame[6] = 0x07
		_, err = server.Write(frame)
		serverDone <- err
		_, _ = io.Copy(io.Discard, server)
	}()

	if err := auth.BeginHandshake(80 * time.Millisecond); err != nil {
		t.Fatalf("BeginHandshake() error = %v", err)
	}
	if err := SetupTunnel(); err != nil {
		t.Fatalf("SetupTunnel() error = %v", err)
	}
	sessionClosed := session.Sess.CloseChan
	if err := <-serverDone; err != nil {
		t.Fatalf("data channel write after handshake budget error = %v", err)
	}
	_ = client.SetDeadline(time.Now())
	_ = client.Close()
	select {
	case <-sessionClosed:
	case <-time.After(time.Second):
		t.Fatal("data channel did not stop after closing test connection")
	}
}

func installTunnelTestConnection(t *testing.T, client *tls.Conn) func() {
	t.Helper()
	oldProf, oldConn, oldBufR := auth.Prof, auth.Conn, auth.BufR
	oldSess := session.Sess
	oldNoTUN, oldNoDTLS := base.Cfg.NoTUN, base.Cfg.NoDTLS

	auth.Prof = &auth.Profile{
		Scheme:       "https://",
		Host:         "gateway.example",
		HostWithPort: "gateway.example:443",
		Username:     "secret-user",
		Password:     "secret-password",
		SecretKey:    "secret-query",
	}
	auth.Conn = client
	auth.BufR = bufio.NewReader(client)
	session.Sess = &session.Session{SessionToken: "secret-token"}
	base.Cfg.NoTUN = true
	base.Cfg.NoDTLS = true

	return func() {
		_ = auth.CompleteHandshake()
		_ = client.SetDeadline(time.Now())
		_ = client.Close()
		auth.Prof, auth.Conn, auth.BufR = oldProf, oldConn, oldBufR
		session.Sess = oldSess
		base.Cfg.NoTUN, base.Cfg.NoDTLS = oldNoTUN, oldNoDTLS
	}
}

func assertTunnelHandshakeTimeout(t *testing.T, err error, stage string) {
	t.Helper()
	if err == nil {
		t.Fatal("expected timeout error")
	}
	if !strings.Contains(err.Error(), "timed out") || !strings.Contains(err.Error(), stage) {
		t.Fatalf("error = %q, want timeout stage %q", err, stage)
	}
}

func assertNoTunnelSecrets(t *testing.T, err error) {
	t.Helper()
	for _, secret := range []string{"secret-user", "secret-password", "secret-query", "secret-token", "gateway.example"} {
		if strings.Contains(err.Error(), secret) {
			t.Fatalf("error leaked %q: %v", secret, err)
		}
	}
}

func tunnelTLSPipe(t *testing.T) (*tls.Conn, *tls.Conn) {
	t.Helper()
	certificate := tunnelTestCertificate(t)
	clientNet, serverNet := net.Pipe()
	client := tls.Client(clientNet, &tls.Config{InsecureSkipVerify: true})
	server := tls.Server(serverNet, &tls.Config{Certificates: []tls.Certificate{certificate}})

	deadline := time.Now().Add(2 * time.Second)
	_ = client.SetDeadline(deadline)
	_ = server.SetDeadline(deadline)
	serverHandshake := make(chan error, 1)
	go func() {
		serverHandshake <- server.Handshake()
	}()
	if err := client.Handshake(); err != nil {
		t.Fatalf("client TLS handshake error = %v", err)
	}
	if err := <-serverHandshake; err != nil {
		t.Fatalf("server TLS handshake error = %v", err)
	}
	_ = client.SetDeadline(time.Time{})
	_ = server.SetDeadline(time.Time{})
	t.Cleanup(func() {
		_ = client.SetDeadline(time.Now())
		_ = server.SetDeadline(time.Now())
		_ = client.Close()
		_ = server.Close()
	})
	return client, server
}

func tunnelTestCertificate(t *testing.T) tls.Certificate {
	t.Helper()
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	template := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "localhost"},
		NotBefore:    time.Now().Add(-time.Minute),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
	}
	der, err := x509.CreateCertificate(rand.Reader, &template, &template, &privateKey.PublicKey, privateKey)
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyDER, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		t.Fatalf("marshal key: %v", err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})
	certificate, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		t.Fatalf("parse certificate: %v", err)
	}
	return certificate
}
