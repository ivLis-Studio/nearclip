//go:build android

package bridge

import (
	"errors"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"time"

	"tailscale.com/net/netmon"
)

// Fix for tailscale/tailscale#17311: in GOOS=android cgo builds (every app that embeds tsnet)
// net.Interfaces fails with "netlinkrib: permission denied" and Tailscale's own fallback
// (feature/androidbin) is compiled out, so netmon cannot start. We register an interface getter
// fed by the app (SetNetwork); until the app reports, a synthetic interface carrying the
// outbound source addresses keeps the node working.

var (
	hooksOnce sync.Once
	reported  atomic.Pointer[[]netmon.Interface]
)

func installPlatformHooks() {
	hooksOnce.Do(func() {
		netmon.RegisterInterfaceGetter(androidInterfaces)
	})
}

func setPlatformNetwork(ni NetInfo) {
	installPlatformHooks()
	var list []netmon.Interface
	for _, it := range ni.Interfaces {
		var flags net.Flags
		if it.Up {
			flags |= net.FlagUp | net.FlagRunning
		}
		if it.Loopback {
			flags |= net.FlagLoopback
		}
		if it.PointToPoint {
			flags |= net.FlagPointToPoint
		}
		if it.Multicast {
			flags |= net.FlagMulticast
		}
		addrs := []net.Addr{}
		for _, p := range parsePrefixes(it.Addrs) {
			addrs = append(addrs, &net.IPNet{IP: p.Addr().AsSlice(), Mask: net.CIDRMask(p.Bits(), p.Addr().BitLen())})
		}
		mtu := it.MTU
		if mtu <= 0 {
			mtu = 1500
		}
		list = append(list, netmon.Interface{
			Interface: &net.Interface{Index: it.Index, MTU: mtu, Name: it.Name, Flags: flags},
			AltAddrs:  addrs,
		})
	}
	if len(list) > 0 {
		reported.Store(&list)
	}
	netmon.UpdateLastKnownDefaultRouteInterface(ni.DefaultInterface)
	netmon.UpdateLastKnownDefaultGateway(ni.Gateway)
}

func androidInterfaces() ([]netmon.Interface, error) {
	if p := reported.Load(); p != nil && len(*p) > 0 {
		return *p, nil
	}
	return syntheticInterfaces()
}

// syntheticInterfaces reports one interface with the addresses the kernel would use for
// outbound traffic. Dialing UDP sends nothing and is allowed in the app sandbox.
func syntheticInterfaces() ([]netmon.Interface, error) {
	var addrs []net.Addr
	if ip, ok := outboundIP("udp4", "8.8.8.8:53"); ok {
		addrs = append(addrs, &net.IPNet{IP: ip.AsSlice(), Mask: net.CIDRMask(32, 32)})
	}
	if ip, ok := outboundIP("udp6", "[2001:4860:4860::8888]:53"); ok {
		addrs = append(addrs, &net.IPNet{IP: ip.AsSlice(), Mask: net.CIDRMask(128, 128)})
	}
	if len(addrs) == 0 {
		return nil, errors.New("no network")
	}
	return []netmon.Interface{{
		Interface: &net.Interface{Index: 1, MTU: 1500, Name: "android", Flags: net.FlagUp | net.FlagRunning},
		AltAddrs:  addrs,
	}}, nil
}

func outboundIP(network, addr string) (netip.Addr, bool) {
	d := net.Dialer{Timeout: 2 * time.Second}
	c, err := d.Dial(network, addr)
	if err != nil {
		return netip.Addr{}, false
	}
	defer c.Close()
	ua, ok := c.LocalAddr().(*net.UDPAddr)
	if !ok {
		return netip.Addr{}, false
	}
	ip, ok := netip.AddrFromSlice(ua.IP)
	if !ok {
		return netip.Addr{}, false
	}
	ip = ip.Unmap()
	if ip.IsLoopback() || ip.IsUnspecified() {
		return netip.Addr{}, false
	}
	return ip, true
}
