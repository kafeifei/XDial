//go:build !windows

package libbox

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/sagernet/sing-box/adapter"
	boxDNS "github.com/sagernet/sing-box/dns"

	mDNS "github.com/miekg/dns"
)

type fakeMobileDNSOwner struct {
	suffixes []string
}

func (o *fakeMobileDNSOwner) claimedSuffixes() []string {
	return append([]string(nil), o.suffixes...)
}

type fakeMobileDNSTransport struct {
	boxDNS.TransportAdapter
	response *mDNS.Msg
	err      error
	calls    int
}

func newFakeMobileDNSTransport(tag string) *fakeMobileDNSTransport {
	return &fakeMobileDNSTransport{
		TransportAdapter: boxDNS.NewTransportAdapter("fake", tag, nil),
	}
}

func (t *fakeMobileDNSTransport) Start(adapter.StartStage) error { return nil }
func (t *fakeMobileDNSTransport) Close() error                   { return nil }
func (t *fakeMobileDNSTransport) Reset()                         {}
func (t *fakeMobileDNSTransport) Exchange(_ context.Context, request *mDNS.Msg) (*mDNS.Msg, error) {
	t.calls++
	if t.err != nil {
		return nil, t.err
	}
	if t.response != nil {
		return t.response.Copy(), nil
	}
	return mobileDNSTestResponse(request, mDNS.RcodeSuccess), nil
}

func (t *fakeMobileDNSTransport) ExchangeAsync(
	ctx context.Context,
	request *mDNS.Msg,
	callback func(response *mDNS.Msg, err error),
) {
	response, err := t.Exchange(ctx, request)
	callback(response, err)
}

type fakeMobileDNSExchanger struct {
	response *mDNS.Msg
	err      error
	calls    int
}

func (e *fakeMobileDNSExchanger) Exchange(_ context.Context, request *mDNS.Msg) (*mDNS.Msg, error) {
	e.calls++
	if e.err != nil {
		return nil, e.err
	}
	return mobileDNSTestResponse(request, mDNS.RcodeSuccess), nil
}

func TestMobileDNSSelectsLongestUniqueSuffix(t *testing.T) {
	shortTransport := newFakeMobileDNSTransport("short")
	longTransport := newFakeMobileDNSTransport("long")
	bindings := []runtimeMobileDNSBinding{
		{
			owner:     &fakeMobileDNSOwner{suffixes: []string{"ts.net"}},
			transport: shortTransport,
		},
		{
			owner:     &fakeMobileDNSOwner{suffixes: []string{"private.ts.net"}},
			transport: longTransport,
		},
	}

	selected, err := selectMobileDNSTransport(bindings, "host.private.ts.net.")
	if err != nil {
		t.Fatal(err)
	}
	if selected != longTransport {
		t.Fatal("longest matching suffix was not selected")
	}
}

func TestMobileDNSSuffixMatchRequiresDomainBoundary(t *testing.T) {
	transport := newFakeMobileDNSTransport("tailnet")
	bindings := []runtimeMobileDNSBinding{{
		owner:     &fakeMobileDNSOwner{suffixes: []string{"example.ts.net"}},
		transport: transport,
	}}

	selected, err := selectMobileDNSTransport(bindings, "notexample.ts.net")
	if err != nil {
		t.Fatal(err)
	}
	if selected != nil {
		t.Fatal("suffix without a label boundary must not match")
	}
}

func TestMobileDNSRejectsAmbiguousEqualOwnership(t *testing.T) {
	first := newFakeMobileDNSTransport("first")
	second := newFakeMobileDNSTransport("second")
	bindings := []runtimeMobileDNSBinding{
		{
			owner:     &fakeMobileDNSOwner{suffixes: []string{"private.ts.net"}},
			transport: first,
		},
		{
			owner:     &fakeMobileDNSOwner{suffixes: []string{"private.ts.net"}},
			transport: second,
		},
	}

	selected, err := selectMobileDNSTransport(bindings, "host.private.ts.net")
	if !errors.Is(err, errMobileDNSAmbiguous) {
		t.Fatalf("expected ambiguous ownership, got transport=%v err=%v", selected, err)
	}
}

func TestMobileDNSUsesPublicFallbackBeforeTailscaleLogin(t *testing.T) {
	tailnet := newFakeMobileDNSTransport("tailnet")
	public := newFakeMobileDNSTransport("public")
	owner := &fakeMobileDNSOwner{}
	dispatcher := &mobileDNSTransport{
		bindings: []runtimeMobileDNSBinding{{
			owner:     owner,
			transport: tailnet,
		}},
		publicFallback: public,
	}

	request := mobileDNSTestRequest("login.tailscale.com.")
	if _, err := dispatcher.Exchange(context.Background(), request); err != nil {
		t.Fatal(err)
	}
	if public.calls != 1 || tailnet.calls != 0 {
		t.Fatalf("unexpected calls: public=%d tailscale=%d", public.calls, tailnet.calls)
	}

	// 模拟同一 endpoint 从 NeedsLogin 原地进入 Running 并收到 DNS reconfig。
	owner.suffixes = []string{"private.ts.net"}
	if _, err := dispatcher.Exchange(context.Background(), mobileDNSTestRequest("host.private.ts.net.")); err != nil {
		t.Fatal(err)
	}
	if public.calls != 1 || tailnet.calls != 1 {
		t.Fatalf("dynamic ownership was not applied: public=%d tailscale=%d", public.calls, tailnet.calls)
	}
}

func TestMobileDNSUsesEnterpriseFallbackWithoutPublicLeak(t *testing.T) {
	public := newFakeMobileDNSTransport("public")
	enterprise := &fakeMobileDNSExchanger{}
	dispatcher := &mobileDNSTransport{
		publicFallback: public,
		enterprise:     enterprise,
	}

	if _, err := dispatcher.Exchange(context.Background(), mobileDNSTestRequest("corp.example.")); err != nil {
		t.Fatal(err)
	}
	if enterprise.calls != 1 || public.calls != 0 {
		t.Fatalf("unexpected calls: enterprise=%d public=%d", enterprise.calls, public.calls)
	}
}

func TestMobileDNSEnterpriseFailureDoesNotFallBackPublic(t *testing.T) {
	public := newFakeMobileDNSTransport("public")
	enterprise := &fakeMobileDNSExchanger{err: errors.New("unavailable")}
	dispatcher := &mobileDNSTransport{
		publicFallback: public,
		enterprise:     enterprise,
	}

	if _, err := dispatcher.Exchange(context.Background(), mobileDNSTestRequest("corp.example.")); !errors.Is(err, errMobileDNSFailed) {
		t.Fatalf("expected fail-closed enterprise error, got %v", err)
	}
	if enterprise.calls != 1 || public.calls != 0 {
		t.Fatalf("unexpected calls: enterprise=%d public=%d", enterprise.calls, public.calls)
	}
}

func TestMobileDNSRequiredEnterpriseWithoutResolverDoesNotFallBackPublic(t *testing.T) {
	public := newFakeMobileDNSTransport("public")
	dispatcher := &mobileDNSTransport{
		publicFallback:     public,
		enterpriseRequired: true,
	}

	if _, err := dispatcher.Exchange(context.Background(), mobileDNSTestRequest("corp.example.")); !errors.Is(err, errMobileDNSFailed) {
		t.Fatalf("expected missing enterprise resolver to fail closed, got %v", err)
	}
	if public.calls != 0 {
		t.Fatalf("missing enterprise resolver leaked to public fallback: calls=%d", public.calls)
	}
}

func TestMobileDNSTailscaleFailureDoesNotFallBack(t *testing.T) {
	tailnet := newFakeMobileDNSTransport("tailnet")
	tailnet.err = errors.New("unavailable")
	public := newFakeMobileDNSTransport("public")
	enterprise := &fakeMobileDNSExchanger{}
	dispatcher := &mobileDNSTransport{
		bindings: []runtimeMobileDNSBinding{{
			owner:     &fakeMobileDNSOwner{suffixes: []string{"private.ts.net"}},
			transport: tailnet,
		}},
		publicFallback: public,
		enterprise:     enterprise,
	}

	if _, err := dispatcher.Exchange(context.Background(), mobileDNSTestRequest("host.private.ts.net.")); !errors.Is(err, errMobileDNSFailed) {
		t.Fatalf("expected fail-closed Tailscale error, got %v", err)
	}
	if tailnet.calls != 1 || enterprise.calls != 0 || public.calls != 0 {
		t.Fatalf(
			"unexpected calls: tailscale=%d enterprise=%d public=%d",
			tailnet.calls,
			enterprise.calls,
			public.calls,
		)
	}
}

func TestMobileDNSAuthoritativeNXDomainDoesNotFallBack(t *testing.T) {
	tailnet := newFakeMobileDNSTransport("tailnet")
	request := mobileDNSTestRequest("missing.private.ts.net.")
	tailnet.response = mobileDNSTestResponse(request, mDNS.RcodeNameError)
	public := newFakeMobileDNSTransport("public")
	dispatcher := &mobileDNSTransport{
		bindings: []runtimeMobileDNSBinding{{
			owner:     &fakeMobileDNSOwner{suffixes: []string{"private.ts.net"}},
			transport: tailnet,
		}},
		publicFallback: public,
	}

	response, err := dispatcher.Exchange(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	if response.Rcode != mDNS.RcodeNameError || tailnet.calls != 1 || public.calls != 0 {
		t.Fatalf("unexpected response/calls: rcode=%d tailscale=%d public=%d", response.Rcode, tailnet.calls, public.calls)
	}
}

func TestMobileDNSIgnoresGlobalAndDuplicateClaims(t *testing.T) {
	got := normalizeMobileDNSSuffixes([]string{".", "", "Private.TS.NET.", "private.ts.net"})
	if len(got) != 1 || got[0] != "private.ts.net" {
		t.Fatalf("unexpected suffixes: %v", got)
	}
}

func TestMobileDNSRejectsMalformedRequest(t *testing.T) {
	dispatcher := &mobileDNSTransport{
		publicFallback: newFakeMobileDNSTransport("public"),
	}
	if _, err := dispatcher.Exchange(context.Background(), &mDNS.Msg{}); err == nil {
		t.Fatal("request without exactly one question must fail")
	}
}

func TestMobileDNSResponseValidationDoesNotExposeQuery(t *testing.T) {
	request := mobileDNSTestRequest("private-name.corp.example.")
	response := mobileDNSTestResponse(request, mDNS.RcodeSuccess)
	response.Id++

	_, err := unpackMobileDNSResponse(mobileDNSPack(t, response), request)
	if !errors.Is(err, errMobileDNSFailed) {
		t.Fatalf("expected response validation failure, got %v", err)
	}
	if strings.Contains(err.Error(), "private-name") || strings.Contains(err.Error(), "corp.example") {
		t.Fatalf("response validation error exposed query: %v", err)
	}
}

func TestMobileDNSRegistrationProvidesOptions(t *testing.T) {
	registry := boxDNS.NewTransportRegistry()
	registerMobileDNSTransport(registry)
	options, loaded := registry.CreateOptions(typeMobileDNS)
	if !loaded {
		t.Fatal("mobile DNS transport was not registered")
	}
	if _, ok := options.(*mobileDNSServerOptions); !ok {
		t.Fatalf("unexpected options type: %T", options)
	}
}

func mobileDNSTestRequest(name string) *mDNS.Msg {
	return &mDNS.Msg{
		MsgHdr: mDNS.MsgHdr{Id: 42, RecursionDesired: true},
		Question: []mDNS.Question{{
			Name:   name,
			Qtype:  mDNS.TypeA,
			Qclass: mDNS.ClassINET,
		}},
	}
}

func mobileDNSTestResponse(request *mDNS.Msg, rcode int) *mDNS.Msg {
	response := new(mDNS.Msg)
	response.SetReply(request)
	response.Rcode = rcode
	return response
}

func mobileDNSPack(t *testing.T, message *mDNS.Msg) []byte {
	t.Helper()
	data, err := message.Pack()
	if err != nil {
		t.Fatal(err)
	}
	return data
}

var _ adapter.DNSTransport = (*fakeMobileDNSTransport)(nil)
