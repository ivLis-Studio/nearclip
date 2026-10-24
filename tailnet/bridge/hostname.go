package bridge

import "strings"

// HostPrefix starts the tailnet hostname of every Nearclip node.
const HostPrefix = "nearclip-"

// MakeHostname returns "nearclip-<name slug>-<first 8 hex digits of the device id>" (≤ 63 chars).
// The id part lets other members recognise the node in the tailnet before connecting.
func MakeHostname(deviceName, deviceID string) string {
	id8 := strings.ReplaceAll(strings.ToLower(deviceID), "-", "")
	if len(id8) > 8 {
		id8 = id8[:8]
	}
	if !isHex(id8) {
		id8 = ""
	}
	var b strings.Builder
	dash := false
	for _, r := range strings.ToLower(deviceName) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
			dash = false
		} else if !dash && b.Len() > 0 {
			b.WriteByte('-')
			dash = true
		}
	}
	slug := strings.Trim(b.String(), "-")
	if len(slug) > 40 {
		slug = strings.Trim(slug[:40], "-")
	}
	h := strings.TrimSuffix(HostPrefix, "-")
	if slug != "" {
		h += "-" + slug
	}
	if id8 != "" {
		h += "-" + id8
	}
	return h
}

// ParseIDPrefix extracts the device-id prefix from a Nearclip hostname ("" if there is none).
func ParseIDPrefix(host string) string {
	if !strings.HasPrefix(host, HostPrefix) {
		return ""
	}
	p := host[strings.LastIndexByte(host, '-')+1:]
	if len(p) == 8 && isHex(p) {
		return p
	}
	return ""
}

func isHex(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f')) {
			return false
		}
	}
	return true
}
