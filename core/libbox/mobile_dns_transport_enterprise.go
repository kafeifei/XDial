//go:build !windows

package libbox

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"net/netip"
	"time"

	"github.com/kafeifei/xdial/core/engine"

	mDNS "github.com/miekg/dns"
)

const mobileDNSQueryTimeout = 3 * time.Second

type bridgeDNSExchanger struct {
	bridge  *engine.VPNBridge
	servers []netip.Addr
}

func newBridgeDNSExchanger(bridge *engine.VPNBridge, servers []netip.Addr) mobileDNSExchanger {
	return &bridgeDNSExchanger{
		bridge:  bridge,
		servers: append([]netip.Addr(nil), servers...),
	}
}

func (e *bridgeDNSExchanger) Exchange(ctx context.Context, message *mDNS.Msg) (*mDNS.Msg, error) {
	if e.bridge == nil || message == nil || len(message.Question) != 1 {
		return nil, errMobileDNSFailed
	}
	query, err := message.Pack()
	if err != nil {
		return nil, errMobileDNSFailed
	}
	for _, server := range e.servers {
		response, truncated, exchangeErr := e.exchangeUDP(ctx, server, query, message)
		if exchangeErr == nil && !truncated {
			return response, nil
		}
		if exchangeErr == nil {
			response, exchangeErr = e.exchangeTCP(ctx, server, query, message)
			if exchangeErr == nil {
				return response, nil
			}
		}
	}
	return nil, errMobileDNSFailed
}

func (e *bridgeDNSExchanger) exchangeUDP(
	ctx context.Context,
	server netip.Addr,
	query []byte,
	request *mDNS.Msg,
) (*mDNS.Msg, bool, error) {
	remote := &net.UDPAddr{IP: net.IP(server.AsSlice()), Port: 53}
	conn, err := e.bridge.DialUDP(nil, remote)
	if err != nil {
		return nil, false, errMobileDNSFailed
	}
	defer conn.Close()
	if err := setMobileDNSDeadline(ctx, conn); err != nil {
		return nil, false, errMobileDNSFailed
	}
	if _, err := conn.Write(query); err != nil {
		return nil, false, errMobileDNSFailed
	}
	buffer := make([]byte, 64*1024)
	n, err := conn.Read(buffer)
	if err != nil {
		return nil, false, errMobileDNSFailed
	}
	response, err := unpackMobileDNSResponse(buffer[:n], request)
	if err != nil {
		return nil, false, err
	}
	return response, response.Truncated, nil
}

func (e *bridgeDNSExchanger) exchangeTCP(
	ctx context.Context,
	server netip.Addr,
	query []byte,
	request *mDNS.Msg,
) (*mDNS.Msg, error) {
	conn, err := e.bridge.DialTCP(ctx, net.JoinHostPort(server.String(), "53"))
	if err != nil {
		return nil, errMobileDNSFailed
	}
	defer conn.Close()
	if err := setMobileDNSDeadline(ctx, conn); err != nil {
		return nil, errMobileDNSFailed
	}
	if len(query) > 0xffff {
		return nil, errMobileDNSFailed
	}
	frame := make([]byte, 2+len(query))
	binary.BigEndian.PutUint16(frame[:2], uint16(len(query)))
	copy(frame[2:], query)
	if _, err := conn.Write(frame); err != nil {
		return nil, errMobileDNSFailed
	}
	var lengthBuffer [2]byte
	if _, err := io.ReadFull(conn, lengthBuffer[:]); err != nil {
		return nil, errMobileDNSFailed
	}
	responseLength := int(binary.BigEndian.Uint16(lengthBuffer[:]))
	if responseLength == 0 {
		return nil, errMobileDNSFailed
	}
	responseData := make([]byte, responseLength)
	if _, err := io.ReadFull(conn, responseData); err != nil {
		return nil, errMobileDNSFailed
	}
	return unpackMobileDNSResponse(responseData, request)
}

func setMobileDNSDeadline(ctx context.Context, conn net.Conn) error {
	deadline := time.Now().Add(mobileDNSQueryTimeout)
	if contextDeadline, ok := ctx.Deadline(); ok && contextDeadline.Before(deadline) {
		deadline = contextDeadline
	}
	return conn.SetDeadline(deadline)
}

func unpackMobileDNSResponse(data []byte, request *mDNS.Msg) (*mDNS.Msg, error) {
	var response mDNS.Msg
	if err := response.Unpack(data); err != nil {
		return nil, errMobileDNSFailed
	}
	if !response.Response || response.Id != request.Id || len(response.Question) != 1 {
		return nil, errMobileDNSFailed
	}
	got := response.Question[0]
	want := request.Question[0]
	if !stringsEqualFoldDNSName(got.Name, want.Name) ||
		got.Qtype != want.Qtype ||
		got.Qclass != want.Qclass {
		return nil, errMobileDNSFailed
	}
	return &response, nil
}

func stringsEqualFoldDNSName(left, right string) bool {
	return normalizeMobileDNSName(left) == normalizeMobileDNSName(right)
}

var _ mobileDNSExchanger = (*bridgeDNSExchanger)(nil)
