package engine

import (
	"context"
	"fmt"
	"net"
	"net/netip"

	"sslcon/proto"
	"sslcon/session"

	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
)

const nicID = 1

type VPNBridge struct {
	s    *stack.Stack
	ep   *channel.Endpoint
	addr netip.Addr
}

func NewVPNBridge(vpnAddr string, mtu int) (*VPNBridge, error) {
	addr, err := netip.ParseAddr(vpnAddr)
	if err != nil {
		return nil, fmt.Errorf("parse vpn addr: %w", err)
	}

	s := stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol},
	})

	ep := channel.New(512, uint32(mtu), "")
	if tcpErr := s.CreateNIC(nicID, ep); tcpErr != nil {
		return nil, fmt.Errorf("create nic: %s", tcpErr)
	}

	a4 := addr.As4()
	protoAddr := tcpip.ProtocolAddress{
		Protocol:          ipv4.ProtocolNumber,
		AddressWithPrefix: tcpip.AddrFromSlice(a4[:]).WithPrefix(),
	}
	if tcpErr := s.AddProtocolAddress(nicID, protoAddr, stack.AddressProperties{}); tcpErr != nil {
		return nil, fmt.Errorf("add addr: %s", tcpErr)
	}

	s.AddRoute(tcpip.Route{
		Destination: header.IPv4EmptySubnet,
		NIC:         nicID,
	})

	return &VPNBridge{s: s, ep: ep, addr: addr}, nil
}

// Start bridges sslcon packet channels ↔ gVisor netstack.
func (b *VPNBridge) Start(cSess *session.ConnSession) {
	go b.vpnToStack(cSess)
	go b.stackToVPN(cSess)
}

// vpnToStack reads decrypted IP packets from sslcon and injects into gVisor.
func (b *VPNBridge) vpnToStack(cSess *session.ConnSession) {
	for {
		select {
		case pl := <-cSess.PayloadIn:
			if pl.Type != 0x00 || len(pl.Data) == 0 {
				continue
			}
			pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{
				Payload: buffer.MakeWithData(pl.Data),
			})
			b.ep.InjectInbound(ipv4.ProtocolNumber, pkt)
			pkt.DecRef()
		case <-cSess.CloseChan:
			return
		}
	}
}

// stackToVPN reads outgoing IP packets from gVisor and sends to sslcon VPN tunnel.
func (b *VPNBridge) stackToVPN(cSess *session.ConnSession) {
	for {
		pkt := b.ep.ReadContext(context.Background())
		if pkt.IsNil() {
			return
		}
		view := pkt.ToView()
		sz := view.Size()
		data := make([]byte, sz, sz+8)
		copy(data, view.AsSlice())
		pkt.DecRef()

		pl := &proto.Payload{Type: 0x00, Data: data}

		if cSess.DtlsConnected.Load() {
			select {
			case cSess.PayloadOutDTLS <- pl:
			case <-cSess.DSess.CloseChan:
			}
		} else {
			select {
			case cSess.PayloadOutTLS <- pl:
			case <-cSess.CloseChan:
				return
			}
		}
	}
}

// DialTCP creates a TCP connection through the VPN tunnel.
func (b *VPNBridge) DialTCP(ctx context.Context, addr string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, err
	}
	ip, err := netip.ParseAddr(host)
	if err != nil {
		return nil, fmt.Errorf("parse addr %s: %w", host, err)
	}
	p, err := net.LookupPort("tcp", port)
	if err != nil {
		return nil, err
	}
	a4 := ip.As4()
	fa := tcpip.FullAddress{
		NIC:  nicID,
		Addr: tcpip.AddrFromSlice(a4[:]),
		Port: uint16(p),
	}
	return gonet.DialContextTCP(ctx, b.s, fa, ipv4.ProtocolNumber)
}

// DialUDP creates a UDP connection through the VPN tunnel.
func (b *VPNBridge) DialUDP(laddr, raddr *net.UDPAddr) (net.Conn, error) {
	var la, ra *tcpip.FullAddress
	if laddr != nil {
		la = &tcpip.FullAddress{Port: uint16(laddr.Port)}
	}
	if raddr != nil {
		ra = &tcpip.FullAddress{
			Addr: tcpip.AddrFromSlice(raddr.IP.To4()),
			Port: uint16(raddr.Port),
		}
	}
	return gonet.DialUDP(b.s, la, ra, ipv4.ProtocolNumber)
}

func (b *VPNBridge) Close() {
	b.ep.Close()
	b.s.Close()
}
