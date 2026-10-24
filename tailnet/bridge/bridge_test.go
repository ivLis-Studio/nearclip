package bridge

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"tailscale.com/tailcfg"
	"tailscale.com/tstest/integration"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/logger"
)

func startControl(t *testing.T) string {
	derpMap := integration.RunDERPAndSTUN(t, logger.Discard, "127.0.0.1")
	control := &testcontrol.Server{
		DERPMap:   derpMap,
		DNSConfig: &tailcfg.DNSConfig{Proxied: true},
		Logf:      logger.Discard,
	}
	control.HTTPTestServer = httptest.NewUnstartedServer(control)
	control.HTTPTestServer.Start()
	t.Cleanup(control.HTTPTestServer.Close)
	return control.HTTPTestServer.URL
}

// echoEngine stands in for a Nearclip engine's loopback listener: it answers each line with tag+line.
func echoEngine(t *testing.T, tag string) string {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				r := bufio.NewReader(c)
				for {
					line, err := r.ReadString('\n')
					if err != nil {
						return
					}
					fmt.Fprintf(c, "%s:%s", tag, line)
				}
			}()
		}
	}()
	return ln.Addr().String()
}

func waitRunning(t *testing.T, b *bridge, peerPrefix string) Status {
	t.Helper()
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		s := b.status(3 * time.Second)
		if s.State == "running" && s.IP != "" {
			for _, p := range s.Peers {
				// testcontrol does not report peer presence, so Online stays false here.
				if p.IDPrefix == peerPrefix {
					return s
				}
			}
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Fatalf("%s: not running with peer %s: %+v", b.hostname, peerPrefix, b.status(3*time.Second))
	return Status{}
}

func proxyDial(t *testing.T, b *bridge, token, target string) (net.Conn, byte) {
	t.Helper()
	c, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", b.proxyPort))
	if err != nil {
		t.Fatal(err)
	}
	fmt.Fprintf(c, "NCTN1 %s %s\n", token, target)
	c.SetReadDeadline(time.Now().Add(20 * time.Second))
	var one [1]byte
	if _, err := io.ReadFull(c, one[:]); err != nil {
		c.Close()
		return nil, 255
	}
	c.SetReadDeadline(time.Time{})
	return c, one[0]
}

func TestBridgeEndToEnd(t *testing.T) {
	controlURL := startControl(t)
	engA := echoEngine(t, "A")
	engB := echoEngine(t, "B")
	mk := func(id, name, fwd string, extra []int) *bridge {
		b, err := start(Config{
			Dir: t.TempDir(), DeviceID: id, DeviceName: name, Forward: fwd, Ports: extra,
			ControlURL: controlURL, Ephemeral: true, TestMode: true,
		})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(b.close)
		return b
	}
	a := mk("aaaa1111-0000-4000-8000-000000000001", "Junseo's MacBook Pro", engA, nil)
	b := mk("bbbb2222-0000-4000-8000-000000000002", "Galaxy S25", engB, []int{50555})
	if a.hostname != "nearclip-junseo-s-macbook-pro-aaaa1111" || b.hostname != "nearclip-galaxy-s25-bbbb2222" {
		t.Fatalf("hostnames %q %q", a.hostname, b.hostname)
	}
	sa := waitRunning(t, a, "bbbb2222")
	sb := waitRunning(t, b, "aaaa1111")
	t.Logf("a=%s b=%s", sa.IP, sb.IP)

	for _, target := range []string{sb.IP + ":45821", sb.IP + ":50555"} {
		c, code := proxyDial(t, a, a.token, target)
		if code != ProxyOK {
			t.Fatalf("proxy to %s: status %d", target, code)
		}
		fmt.Fprintf(c, "hello\n")
		c.SetReadDeadline(time.Now().Add(10 * time.Second))
		line, err := bufio.NewReader(c).ReadString('\n')
		c.Close()
		if err != nil || line != "B:hello\n" {
			t.Fatalf("relay via %s: %q %v", target, line, err)
		}
	}
	// And the other way round.
	c, code := proxyDial(t, b, b.token, sa.IP+":45821")
	if code != ProxyOK {
		t.Fatalf("b->a status %d", code)
	}
	fmt.Fprintf(c, "back\n")
	line, _ := bufio.NewReader(c).ReadString('\n')
	c.Close()
	if line != "A:back\n" {
		t.Fatalf("b->a relay %q", line)
	}

	if _, code := proxyDial(t, a, strings.Repeat("0", 32), sb.IP+":45821"); code != ProxyBadRequest {
		t.Fatalf("bad token: status %d", code)
	}
	if _, code := proxyDial(t, a, a.token, "1.1.1.1:80"); code != ProxyBadRequest {
		t.Fatalf("non-tailnet target: status %d", code)
	}
	if _, code := proxyDial(t, a, a.token, sb.IP+":45999"); code != ProxyDialFailed {
		t.Fatalf("closed port: status %d", code)
	}
}

func TestHostnames(t *testing.T) {
	cases := map[[2]string]string{
		{"준서의 iPhone", "3F2B8C1E-9A4D-4C47-B0D2-6C1F5E8A9B10"}: "nearclip-iphone-3f2b8c1e",
		{"", "3f2b8c1e-9a4d-4c47-b0d2-6c1f5e8a9b10"}:            "nearclip-3f2b8c1e",
		{"DESKTOP-STUDIO", "zz"}:                                "nearclip-desktop-studio",
		{strings.Repeat("abc ", 30), "01234567-89ab"}:           "nearclip-abc-abc-abc-abc-abc-abc-abc-abc-abc-abc-01234567",
	}
	for in, want := range cases {
		if got := MakeHostname(in[0], in[1]); got != want {
			t.Errorf("MakeHostname(%q, %q) = %q, want %q", in[0], in[1], got, want)
		}
		if len(MakeHostname(in[0], in[1])) > 63 {
			t.Errorf("too long")
		}
	}
	if p := ParseIDPrefix("nearclip-iphone-3f2b8c1e"); p != "3f2b8c1e" {
		t.Errorf("parse %q", p)
	}
	if p := ParseIDPrefix("nearclip-desktop-studio"); p != "" {
		t.Errorf("parse no id %q", p)
	}
	if p := ParseIDPrefix("laptop-3f2b8c1e"); p != "" {
		t.Errorf("parse foreign %q", p)
	}
}
