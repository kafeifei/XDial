//go:build !windows

package libbox

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"sync/atomic"
	"time"

	"github.com/sagernet/sing-box/adapter"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/common/ntp"
)

const (
	outboundTLSFailureTimeout        = "timeout"
	outboundTLSFailureCancelled      = "cancelled"
	outboundTLSFailureTCPConnect     = "tcp-connect-failed"
	outboundTLSFailurePeerClosed     = "tls-peer-closed"
	outboundTLSFailureAuthentication = "tls-authentication-failed"
	outboundTLSFailureHandshake      = "tls-handshake-failed"
	minimumOutboundTLSProbeTimeoutMS = 500
	maximumOutboundTLSProbeTimeoutMS = 10_000
)

type outboundTLSProbeTarget struct {
	address    netip.Addr
	port       uint16
	serverName string
}

type outboundTLSProbeTargetSet struct {
	ipv4 []outboundTLSProbeTarget
	ipv6 []outboundTLSProbeTarget
}

var fixedOutboundTLSProbeTargets = outboundTLSProbeTargetSet{
	ipv4: []outboundTLSProbeTarget{
		{
			address:    netip.MustParseAddr("1.1.1.1"),
			port:       443,
			serverName: "one.one.one.one",
		},
	},
	ipv6: []outboundTLSProbeTarget{
		{
			address:    netip.MustParseAddr("2606:4700:4700::1111"),
			port:       443,
			serverName: "one.one.one.one",
		},
	},
}

type outboundTLSFamilyCapability struct {
	Available        bool           `json:"available"`
	Attempts         int            `json:"attempts"`
	TCPConnected     int            `json:"tcp_connected"`
	TLSAuthenticated int            `json:"tls_authenticated"`
	FailureCodes     map[string]int `json:"failure_codes"`
}

type outboundTLSCapabilities struct {
	IPv4 outboundTLSFamilyCapability `json:"ipv4"`
	IPv6 outboundTLSFamilyCapability `json:"ipv6"`
}

type outboundTLSAttemptResult struct {
	tcpConnected     bool
	tlsAuthenticated bool
	failureCode      string
}

type outboundTLSProbeJob struct {
	family string
	target outboundTLSProbeTarget
}

type outboundTLSProbeJobResult struct {
	family string
	result outboundTLSAttemptResult
}

type outboundTLSReadCountingConn struct {
	net.Conn
	readBytes atomic.Int64
}

func (c *outboundTLSReadCountingConn) Read(buffer []byte) (int, error) {
	count, err := c.Conn.Read(buffer)
	c.readBytes.Add(int64(count))
	return count, err
}

// ProbeOutboundTLSCapabilities authenticates TLS through one exact running
// outbound for the exact IPv4 and IPv6 literals used by the Line's DoH
// transport. The SNI names are used only by TLS verification and are never
// handed to the outbound for DNS resolution.
func (l *Libbox) ProbeOutboundTLSCapabilities(
	outboundTag string,
	timeoutMS int,
) (string, error) {
	l.mu.Lock()
	if !l.running || l.box == nil || l.runtimeCtx == nil ||
		l.switchCommitInProgress {
		l.mu.Unlock()
		return "", fmt.Errorf("connection is not running")
	}
	timeoutMS = clampOutboundTLSProbeTimeout(timeoutMS)
	outbound, loaded := l.box.Outbound().Outbound(outboundTag)
	if !loaded {
		l.mu.Unlock()
		return "", fmt.Errorf("probe outbound is unavailable")
	}
	ctx, cancel := context.WithTimeout(
		l.runtimeCtx,
		time.Duration(timeoutMS)*time.Millisecond,
	)
	generation := l.boxGeneration
	probe := l.probeOutboundTLSCapabilitiesFunc
	if probe == nil {
		probe = probeOutboundTLSCapabilities
	}
	l.runtimeUsers.Add(1)
	l.mu.Unlock()
	defer l.runtimeUsers.Done()
	defer cancel()

	capabilities := probe(ctx, outbound)
	if !l.probeGenerationIsCurrent(generation) {
		return "", fmt.Errorf(
			"connection changed during outbound TLS probe",
		)
	}
	return marshalOutboundTLSCapabilities(capabilities)
}

// ProbePreparedSwitchOutboundTLSCapabilities applies the same exact-outbound
// TLS readiness contract to the unpublished switch candidate.
func (l *Libbox) ProbePreparedSwitchOutboundTLSCapabilities(
	outboundTag string,
	timeoutMS int,
) (string, error) {
	l.mu.Lock()
	candidate := l.preparedSwitch
	if candidate == nil || candidate.box == nil ||
		candidate.runtimeCtx == nil || l.switchCommitInProgress {
		l.mu.Unlock()
		return "", fmt.Errorf("switch candidate is not prepared")
	}
	timeoutMS = clampOutboundTLSProbeTimeout(timeoutMS)
	outbound, loaded := candidate.box.Outbound().Outbound(outboundTag)
	if !loaded {
		l.mu.Unlock()
		return "", fmt.Errorf("switch probe outbound is unavailable")
	}
	ctx, cancel := context.WithTimeout(
		candidate.runtimeCtx,
		time.Duration(timeoutMS)*time.Millisecond,
	)
	probe := l.probeOutboundTLSCapabilitiesFunc
	if probe == nil {
		probe = probeOutboundTLSCapabilities
	}
	l.switchCandidateUsers.Add(1)
	l.mu.Unlock()
	defer l.switchCandidateUsers.Done()
	defer cancel()

	capabilities := probe(ctx, outbound)
	if !l.preparedSwitchIsCurrent(candidate) {
		return "", fmt.Errorf(
			"switch candidate changed during outbound TLS probe",
		)
	}
	return marshalOutboundTLSCapabilities(capabilities)
}

func clampOutboundTLSProbeTimeout(timeoutMS int) int {
	if timeoutMS < minimumOutboundTLSProbeTimeoutMS {
		return minimumOutboundTLSProbeTimeoutMS
	}
	if timeoutMS > maximumOutboundTLSProbeTimeoutMS {
		return maximumOutboundTLSProbeTimeoutMS
	}
	return timeoutMS
}

func marshalOutboundTLSCapabilities(
	capabilities outboundTLSCapabilities,
) (string, error) {
	if capabilities.IPv4.FailureCodes == nil {
		capabilities.IPv4.FailureCodes = make(map[string]int)
	}
	if capabilities.IPv6.FailureCodes == nil {
		capabilities.IPv6.FailureCodes = make(map[string]int)
	}
	encoded, err := json.Marshal(capabilities)
	if err != nil {
		return "", fmt.Errorf("outbound TLS probe result is unavailable")
	}
	return string(encoded), nil
}

func probeOutboundTLSCapabilities(
	ctx context.Context,
	outbound adapter.Outbound,
) outboundTLSCapabilities {
	return probeOutboundTLSCapabilitiesWithTargets(
		ctx,
		outbound,
		fixedOutboundTLSProbeTargets,
	)
}

func probeOutboundTLSCapabilitiesWithTargets(
	ctx context.Context,
	outbound adapter.Outbound,
	targets outboundTLSProbeTargetSet,
) outboundTLSCapabilities {
	capabilities := outboundTLSCapabilities{
		IPv4: newOutboundTLSFamilyCapability(len(targets.ipv4)),
		IPv6: newOutboundTLSFamilyCapability(len(targets.ipv6)),
	}
	jobs := make([]outboundTLSProbeJob, 0, len(targets.ipv4)+len(targets.ipv6))
	for _, target := range targets.ipv4 {
		jobs = append(jobs, outboundTLSProbeJob{family: "ipv4", target: target})
	}
	for _, target := range targets.ipv6 {
		jobs = append(jobs, outboundTLSProbeJob{family: "ipv6", target: target})
	}
	results := make(chan outboundTLSProbeJobResult, len(jobs))
	for _, job := range jobs {
		go func(job outboundTLSProbeJob) {
			results <- outboundTLSProbeJobResult{
				family: job.family,
				result: probeOutboundTLSAttempt(ctx, outbound, job.target),
			}
		}(job)
	}
	for range jobs {
		jobResult := <-results
		if jobResult.family == "ipv4" {
			addOutboundTLSAttemptResult(&capabilities.IPv4, jobResult.result)
		} else {
			addOutboundTLSAttemptResult(&capabilities.IPv6, jobResult.result)
		}
	}
	return capabilities
}

func newOutboundTLSFamilyCapability(attempts int) outboundTLSFamilyCapability {
	return outboundTLSFamilyCapability{
		Attempts:     attempts,
		FailureCodes: make(map[string]int),
	}
}

func addOutboundTLSAttemptResult(
	capability *outboundTLSFamilyCapability,
	result outboundTLSAttemptResult,
) {
	if result.tcpConnected {
		capability.TCPConnected++
	}
	if result.tlsAuthenticated {
		capability.TLSAuthenticated++
		capability.Available = true
	}
	if result.failureCode != "" {
		capability.FailureCodes[result.failureCode]++
	}
}

func probeOutboundTLSAttempt(
	ctx context.Context,
	outbound adapter.Outbound,
	target outboundTLSProbeTarget,
) outboundTLSAttemptResult {
	destination := M.SocksaddrFrom(target.address, target.port)
	conn, err := outbound.DialContext(ctx, "tcp", destination)
	if err != nil {
		return outboundTLSAttemptResult{
			failureCode: classifyOutboundTLSDialFailure(ctx, err),
		}
	}
	defer conn.Close()

	countingConn := &outboundTLSReadCountingConn{Conn: conn}
	tlsConn := tls.Client(countingConn, &tls.Config{
		MinVersion: tls.VersionTLS12,
		ServerName: target.serverName,
		RootCAs:    adapter.RootPoolFromContext(ctx),
		Time:       ntp.TimeFuncFromContext(ctx),
	})
	if err := tlsConn.HandshakeContext(ctx); err != nil {
		return outboundTLSAttemptResult{
			tcpConnected: true,
			failureCode: classifyOutboundTLSHandshakeFailure(
				ctx,
				err,
				countingConn.readBytes.Load(),
			),
		}
	}
	return outboundTLSAttemptResult{
		tcpConnected:     true,
		tlsAuthenticated: true,
	}
}

func classifyOutboundTLSDialFailure(ctx context.Context, err error) string {
	if code := classifyOutboundTLSContextFailure(ctx, err); code != "" {
		return code
	}
	return outboundTLSFailureTCPConnect
}

func classifyOutboundTLSHandshakeFailure(
	ctx context.Context,
	err error,
	readBytes int64,
) string {
	if code := classifyOutboundTLSContextFailure(ctx, err); code != "" {
		return code
	}
	var verificationError *tls.CertificateVerificationError
	if errors.As(err, &verificationError) {
		return outboundTLSFailureAuthentication
	}
	var certificateInvalidError x509.CertificateInvalidError
	var hostnameError x509.HostnameError
	var unknownAuthorityError x509.UnknownAuthorityError
	if errors.As(err, &certificateInvalidError) ||
		errors.As(err, &hostnameError) ||
		errors.As(err, &unknownAuthorityError) {
		return outboundTLSFailureAuthentication
	}
	if readBytes == 0 || errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return outboundTLSFailurePeerClosed
	}
	return outboundTLSFailureHandshake
}

func classifyOutboundTLSContextFailure(ctx context.Context, err error) string {
	if errors.Is(ctx.Err(), context.DeadlineExceeded) ||
		errors.Is(err, context.DeadlineExceeded) {
		return outboundTLSFailureTimeout
	}
	if errors.Is(ctx.Err(), context.Canceled) ||
		errors.Is(err, context.Canceled) {
		return outboundTLSFailureCancelled
	}
	var networkError net.Error
	if errors.As(err, &networkError) && networkError.Timeout() {
		return outboundTLSFailureTimeout
	}
	return ""
}
