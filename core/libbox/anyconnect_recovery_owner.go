//go:build !windows

package libbox

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	stdjson "encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"syscall"

	"github.com/kafeifei/xdial/core/engine"
	"sslcon/session"
)

// A recovery belongs to the leased protocol capability, never to the Box or
// the candidate that first waited for it. Cancelling a waiter cannot cancel a
// committed Line's recovery; the pool's last-lease boundary cancels the owner.
type anyConnectRecovery struct {
	done    chan struct{}
	settled chan struct{}
	err     error
}

func (c *anyConnectRuntimeCapability) attachOwner(l *Libbox, networkManaged bool) context.Context {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ownerCtx == nil {
		c.ownerCtx, c.ownerCancel = context.WithCancel(context.Background())
		if c.stopped {
			c.ownerCancel()
		}
	}
	if c.owner == nil {
		c.owner = l
	}
	c.networkManaged = c.networkManaged || networkManaged
	return c.ownerCtx
}

func (c *anyConnectRuntimeCapability) cancelOwner() {
	c.mu.Lock()
	if c.ownerCancel != nil {
		c.ownerCancel()
	}
	c.mu.Unlock()
}

func (c *anyConnectRuntimeCapability) observeNetwork(epoch string, config *engine.VPNConfig) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.networkEpoch != epoch {
		c.networkEpoch = epoch
		c.lastRecoveryError = nil
	}
	if config != nil {
		c.config = *config
	}
}

func (c *anyConnectRuntimeCapability) ensureTransport(ctx context.Context, force bool, expectedRevision ...uint64) error {
	c.mu.Lock()
	if c.stopped || c.ownerCtx == nil || c.ownerCtx.Err() != nil {
		c.mu.Unlock()
		return context.Canceled
	}
	work := c.recovery
	if work == nil {
		if c.networkManaged && c.lastRecoveryEpoch == c.networkEpoch && c.lastRecoveryRevision == c.revision {
			if c.lastRecoveryError != nil {
				err := c.lastRecoveryError
				c.mu.Unlock()
				return err
			}
			// A successful protocol recovery followed by an unsuccessful exit
			// proof does not grant each Scene another login budget. A genuinely
			// closed session still starts its own owner recovery below.
			if force && preparedAnyConnectSessionAlive(c.session) {
				c.mu.Unlock()
				return nil
			}
		}
		if force && len(expectedRevision) > 0 && c.revision != expectedRevision[0] && c.bridge != nil && preparedAnyConnectSessionAlive(c.session) {
			c.mu.Unlock()
			return nil
		}
		if !force && c.bridge != nil && c.line != nil && c.line.available() && preparedAnyConnectSessionAlive(c.session) {
			c.mu.Unlock()
			return nil
		}
		work = &anyConnectRecovery{done: make(chan struct{}), settled: make(chan struct{})}
		c.lastRecoverySettled = work.settled
		c.recovery = work
		go c.runRecovery(work)
	}
	c.mu.Unlock()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-work.done:
		return work.err
	}
}

func (c *anyConnectRuntimeCapability) runRecovery(work *anyConnectRecovery) {
	defer close(work.settled)
	c.mu.Lock()
	owner, ctx, config, strict := c.owner, c.ownerCtx, c.config, c.networkManaged
	epoch := c.networkEpoch
	oldBridge, oldSession := c.bridge, c.session
	c.mu.Unlock()
	if oldBridge != nil {
		c.deactivate(oldBridge, oldSession)
	}
	owner.syncAnyConnectCapability(c)
	if oldBridge != nil {
		oldBridge.Close()
	}
	if c.vpn != nil {
		c.vpn.Disconnect()
	}
	var lastErr error
	for attempt := 1; attempt <= maxAnyConnectReconnectAttempts; attempt++ {
		if !waitForAnyConnectReconnect(ctx, owner.anyConnectReconnectDelay(attempt)) {
			lastErr = ctx.Err()
			break
		}
		owner.notifyAnyConnectCapability(c, "line_reconnecting", attempt)
		info, err := c.vpn.Connect(config)
		if err != nil {
			lastErr = err
			c.vpn.Disconnect()
			if strict && !transientLineReadinessError(err) {
				break
			}
			continue
		}
		if ctx.Err() != nil {
			c.vpn.Disconnect()
			lastErr = ctx.Err()
			break
		}
		dns := anyConnectDNSServers(info.DNS)
		if len(dns) == 0 {
			lastErr = fmt.Errorf("AnyConnect did not provide a usable DNS server")
			c.vpn.Disconnect()
			break
		}
		bridge, err := engine.NewVPNBridge(info.VPNAddress, info.MTU)
		if err != nil {
			lastErr = err
			c.vpn.Disconnect()
			break
		}
		sess := c.vpn.Session()
		if sess == nil || !preparedAnyConnectSessionAlive(sess) {
			lastErr = io.EOF
			bridge.Close()
			c.vpn.Disconnect()
			continue
		}
		bridge.Start(sess)
		encoded, _ := stdjson.Marshal(dns)
		if ctx.Err() != nil || !c.activate(bridge, sess, string(encoded), dns) {
			bridge.Close()
			c.vpn.Disconnect()
			lastErr = context.Canceled
			break
		}
		owner.syncAnyConnectCapability(c)
		owner.notifyAnyConnectCapability(c, "line_connected", attempt)
		lastErr = nil
		break
	}
	c.mu.Lock()
	work.err = lastErr
	c.lastRecoveryEpoch, c.lastRecoveryRevision, c.lastRecoveryError = epoch, c.revision, lastErr
	if c.recovery == work {
		c.recovery = nil
	}
	close(work.done)
	sess := c.session
	c.mu.Unlock()
	if lastErr == nil && sess != nil {
		owner.monitorRecoveredCapability(c, sess)
	} else if lastErr != nil && ctx.Err() == nil {
		owner.failAnyConnectCapabilityRecovery(c, epoch)
	}
}

func (c *anyConnectRuntimeCapability) waitRecoverySettlement() {
	c.mu.Lock()
	settled := c.lastRecoverySettled
	c.mu.Unlock()
	if settled != nil {
		<-settled
	}
}

func (l *Libbox) failAnyConnectCapabilityRecovery(c *anyConnectRuntimeCapability, epoch string) {
	l.mu.Lock()
	active := l.running && !l.cleaning && l.activeAnyConnectCapability == c && l.session == nil
	generation, line := l.generation, l.anyConnectLine
	failureMessage := anyConnectFailureMessage(l.anyConnectDiagnostics)
	c.mu.Lock()
	current := c.networkEpoch == epoch
	c.mu.Unlock()
	l.mu.Unlock()
	if active && current {
		l.failAfterAnyConnectReconnect(generation, line, failureMessage)
	}
}

// Keep Libbox's diagnostic projection synchronized only while this capability
// is still the active one. Candidate recovery cannot publish an active Line.
func (l *Libbox) syncAnyConnectCapability(c *anyConnectRuntimeCapability) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.activeAnyConnectCapability != c || !l.running || l.cleaning {
		return
	}
	snapshot := c.snapshot()
	l.bridge, l.session, l.anyConnectLine = snapshot.bridge, snapshot.session, snapshot.line
	l.dnsJSON = snapshot.dnsJSON
	if snapshot.session != nil {
		l.lastError = ""
		l.anyConnectDiagnostics = nil
	}
}

func (l *Libbox) notifyAnyConnectCapability(c *anyConnectRuntimeCapability, state string, attempt int) {
	l.mu.Lock()
	active := l.running && !l.cleaning && l.activeAnyConnectCapability == c
	l.mu.Unlock()
	if active {
		l.notifyStatus(anyConnectLineStatusJSON(state, attempt, maxAnyConnectReconnectAttempts))
	}
}

func (l *Libbox) monitorRecoveredCapability(c *anyConnectRuntimeCapability, sess *session.ConnSession) {
	l.mu.Lock()
	active := l.running && !l.cleaning && l.activeAnyConnectCapability == c && l.session == sess
	generation := l.generation
	l.mu.Unlock()
	if active {
		go l.monitorSession(generation, sess)
	}
}

// Classification is based solely on typed causes. sslcon's untyped auth and
// configuration failures intentionally stay terminal until it exposes a typed
// contract; an unknown string must never start an automatic retry loop.
func transientLineReadinessError(err error) bool {
	if err == nil {
		return false
	}
	var verification *tls.CertificateVerificationError
	var unknownAuthority x509.UnknownAuthorityError
	var invalid x509.CertificateInvalidError
	var hostname x509.HostnameError
	if errors.As(err, &verification) || errors.As(err, &unknownAuthority) || errors.As(err, &invalid) || errors.As(err, &hostname) {
		return false
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return true
	}
	var networkError net.Error
	if errors.As(err, &networkError) && (networkError.Timeout() || networkError.Temporary()) {
		return true
	}
	for _, cause := range []error{syscall.ECONNRESET, syscall.ECONNREFUSED, syscall.ENETUNREACH, syscall.EHOSTUNREACH, syscall.ETIMEDOUT, syscall.ENETDOWN, syscall.EPIPE} {
		if errors.Is(err, cause) {
			return true
		}
	}
	return false
}
