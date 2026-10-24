package bridge

import (
	"encoding/json"
	"net/netip"
)

// NetInfo describes the device's networks. Android apps cannot enumerate interfaces from Go
// (netlink is denied to app UIDs since Android 11 — tailscale/tailscale#17311), so the app
// reports them from ConnectivityManager / NetworkInterface.
type NetInfo struct {
	Interfaces       []NetInterface `json:"interfaces"`
	DefaultInterface string         `json:"defaultInterface,omitempty"`
	Gateway          string         `json:"gateway,omitempty"`
}

type NetInterface struct {
	Name         string   `json:"name"`
	Index        int      `json:"index"`
	MTU          int      `json:"mtu"`
	Up           bool     `json:"up"`
	Loopback     bool     `json:"loopback,omitempty"`
	PointToPoint bool     `json:"pointToPoint,omitempty"`
	Multicast    bool     `json:"multicast,omitempty"`
	Addrs        []string `json:"addrs"` // CIDR, e.g. "192.168.0.12/24"
}

// SetNetwork records the device's interfaces (used on Android) and signals a network change.
func SetNetwork(js []byte) error {
	var ni NetInfo
	if len(js) > 0 {
		if err := json.Unmarshal(js, &ni); err != nil {
			return err
		}
	}
	setPlatformNetwork(ni)
	NetworkChanged()
	return nil
}

func parsePrefixes(addrs []string) []netip.Prefix {
	var out []netip.Prefix
	for _, a := range addrs {
		if p, err := netip.ParsePrefix(a); err == nil {
			out = append(out, p)
		} else if ip, err := netip.ParseAddr(a); err == nil {
			out = append(out, netip.PrefixFrom(ip, ip.BitLen()))
		}
	}
	return out
}
