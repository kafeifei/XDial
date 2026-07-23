package auth

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

	"sslcon/proto"
)

func TestTplPostTimesOutWhenServerDoesNotRespond(t *testing.T) {
	client, server := authenticatedTLSPipe(t)
	restore := installAuthTestConnection(t, client)
	defer restore()

	requestRead := make(chan struct{})
	go func() {
		_, _ = http.ReadRequest(bufio.NewReader(server))
		close(requestRead)
		time.Sleep(120 * time.Millisecond)
		_, _ = io.Copy(io.Discard, server)
	}()

	if err := BeginHandshake(80 * time.Millisecond); err != nil {
		t.Fatalf("BeginHandshake() error = %v", err)
	}
	err := tplPost(tplInit, "", new(proto.DTD))
	<-requestRead

	assertHandshakeTimeout(t, err, "authentication response")
	assertNoAuthSecrets(t, err)
}

func TestEnsureHandshakeDoesNotExtendTotalBudget(t *testing.T) {
	client, server := authenticatedTLSPipe(t)
	restore := installAuthTestConnection(t, client)
	defer restore()

	go func() {
		_, _ = http.ReadRequest(bufio.NewReader(server))
		_, _ = io.Copy(io.Discard, server)
	}()

	started := time.Now()
	if err := BeginHandshake(160 * time.Millisecond); err != nil {
		t.Fatalf("BeginHandshake() error = %v", err)
	}
	time.Sleep(100 * time.Millisecond)
	if err := EnsureHandshake(); err != nil {
		t.Fatalf("EnsureHandshake() error = %v", err)
	}
	err := tplPost(tplInit, "", new(proto.DTD))
	elapsed := time.Since(started)

	assertHandshakeTimeout(t, err, "authentication response")
	if elapsed > 220*time.Millisecond {
		t.Fatalf("total handshake budget was extended: elapsed = %s", elapsed)
	}
}

func TestTplPostTimesOutWhenServerRespondsLate(t *testing.T) {
	client, server := authenticatedTLSPipe(t)
	restore := installAuthTestConnection(t, client)
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
		_, _ = server.Write([]byte("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
		<-drained
	}()

	if err := BeginHandshake(80 * time.Millisecond); err != nil {
		t.Fatalf("BeginHandshake() error = %v", err)
	}
	err := tplPost(tplInit, "", new(proto.DTD))
	<-serverDone

	assertHandshakeTimeout(t, err, "authentication response")
	assertNoAuthSecrets(t, err)
}

func TestTplPostTimesOutWhileReadingResponseBody(t *testing.T) {
	client, server := authenticatedTLSPipe(t)
	restore := installAuthTestConnection(t, client)
	defer restore()

	go func() {
		_, _ = http.ReadRequest(bufio.NewReader(server))
		_, _ = server.Write([]byte("HTTP/1.1 200 OK\r\nContent-Length: 128\r\n\r\n<config-auth"))
		time.Sleep(120 * time.Millisecond)
		_, _ = io.Copy(io.Discard, server)
	}()

	if err := BeginHandshake(80 * time.Millisecond); err != nil {
		t.Fatalf("BeginHandshake() error = %v", err)
	}
	err := tplPost(tplInit, "", new(proto.DTD))

	assertHandshakeTimeout(t, err, "authentication response body")
	assertNoAuthSecrets(t, err)
}

func TestTplPostReadsNormalResponseWithinBudget(t *testing.T) {
	client, server := authenticatedTLSPipe(t)
	restore := installAuthTestConnection(t, client)
	defer restore()

	body := `<config-auth type="auth-request"><auth><form action="/next"/></auth></config-auth>`
	serverDone := make(chan error, 1)
	go func() {
		req, err := http.ReadRequest(bufio.NewReader(server))
		if err != nil {
			serverDone <- err
			return
		}
		if req.Method != http.MethodPost {
			serverDone <- fmt.Errorf("method = %s", req.Method)
			return
		}
		_, err = fmt.Fprintf(server, "HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n%s", len(body), body)
		serverDone <- err
		_, _ = io.Copy(io.Discard, server)
	}()

	if err := BeginHandshake(time.Second); err != nil {
		t.Fatalf("BeginHandshake() error = %v", err)
	}
	dtd := new(proto.DTD)
	if err := tplPost(tplInit, "", dtd); err != nil {
		t.Fatalf("tplPost() error = %v", err)
	}
	if err := <-serverDone; err != nil {
		t.Fatalf("server error = %v", err)
	}
	if got := dtd.Type; got != "auth-request" {
		t.Fatalf("DTD type = %q, want auth-request", got)
	}
}

func installAuthTestConnection(t *testing.T, client *tls.Conn) func() {
	t.Helper()
	oldProf, oldConn, oldBufR := Prof, Conn, BufR
	oldDeadline := handshakeDeadline

	Prof = &Profile{
		Scheme:       "https://",
		HostWithPort: "gateway.example:443",
		Username:     "secret-user",
		Password:     "secret-password",
		SecretKey:    "secret-query",
	}
	Conn = client
	BufR = bufio.NewReader(client)
	handshakeDeadline = time.Time{}

	return func() {
		_ = client.SetDeadline(time.Now())
		_ = client.Close()
		Prof, Conn, BufR = oldProf, oldConn, oldBufR
		handshakeDeadline = oldDeadline
	}
}

func assertHandshakeTimeout(t *testing.T, err error, stage string) {
	t.Helper()
	if err == nil {
		t.Fatal("expected timeout error")
	}
	if !strings.Contains(err.Error(), "timed out") || !strings.Contains(err.Error(), stage) {
		t.Fatalf("error = %q, want timeout stage %q", err, stage)
	}
}

func assertNoAuthSecrets(t *testing.T, err error) {
	t.Helper()
	for _, secret := range []string{"secret-user", "secret-password", "secret-query", "gateway.example"} {
		if strings.Contains(err.Error(), secret) {
			t.Fatalf("error leaked %q: %v", secret, err)
		}
	}
}

func authenticatedTLSPipe(t *testing.T) (*tls.Conn, *tls.Conn) {
	t.Helper()
	certificate := testCertificate(t)
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

func testCertificate(t *testing.T) tls.Certificate {
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
