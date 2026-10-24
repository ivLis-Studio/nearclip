// Command nctestcontrol runs a throwaway Tailscale control server with its own DERP relay and
// STUN server for Nearclip's automated tests. Every node that connects is approved at once.
// It prints {"controlURL": ...} on stdout and exits when stdin is closed.
package main

import (
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"strconv"

	"tailscale.com/derp/derpserver"
	"tailscale.com/net/stun"
	"tailscale.com/tailcfg"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
)

func main() {
	listen := flag.String("listen", "127.0.0.1", "IP to listen on (0.0.0.0 to serve emulators and VMs)")
	announce := flag.String("ip", "", "IP that nodes use to reach this server (default: -listen)")
	port := flag.Int("port", 0, "control port (0 = any)")
	verbose := flag.Bool("v", false, "log to stderr")
	flag.Parse()
	ip := *announce
	if ip == "" {
		ip = *listen
	}
	logf := logger.Discard
	if *verbose {
		logf = log.Printf
	}

	d := derpserver.New(key.NewNode(), logf)
	dln, err := net.Listen("tcp", net.JoinHostPort(*listen, "0"))
	check(err)
	derpSrv := httptest.NewUnstartedServer(derpserver.Handler(d))
	derpSrv.Listener.Close()
	derpSrv.Listener = dln
	derpSrv.Config.TLSNextProto = make(map[string]func(*http.Server, *tls.Conn, http.Handler))
	derpSrv.StartTLS()

	pc, err := net.ListenPacket("udp4", net.JoinHostPort(*listen, "0"))
	check(err)
	go serveSTUN(pc.(*net.UDPConn))

	derpMap := &tailcfg.DERPMap{Regions: map[tailcfg.DERPRegionID]*tailcfg.DERPRegion{
		1: {RegionID: 1, RegionCode: "test", RegionName: "Nearclip test", Nodes: []*tailcfg.DERPNode{{
			Name: "t1", RegionID: 1, HostName: ip, IPv4: ip, IPv6: "none",
			STUNPort:         pc.LocalAddr().(*net.UDPAddr).Port,
			DERPPort:         dln.Addr().(*net.TCPAddr).Port,
			InsecureForTests: true,
			STUNTestIP:       ip,
		}}},
	}}
	control := &testcontrol.Server{DERPMap: derpMap, DNSConfig: &tailcfg.DNSConfig{Proxied: true}, Logf: logf}
	cln, err := net.Listen("tcp", net.JoinHostPort(*listen, strconv.Itoa(*port)))
	check(err)
	go http.Serve(cln, control)
	fmt.Printf("{\"controlURL\":\"http://%s\"}\n", net.JoinHostPort(ip, strconv.Itoa(cln.Addr().(*net.TCPAddr).Port)))
	io.Copy(io.Discard, os.Stdin)
}

func serveSTUN(pc *net.UDPConn) {
	buf := make([]byte, 64<<10)
	for {
		n, src, err := pc.ReadFromUDPAddrPort(buf)
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			continue
		}
		pkt := buf[:n]
		if !stun.Is(pkt) {
			continue
		}
		txid, err := stun.ParseBindingRequest(pkt)
		if err != nil {
			continue
		}
		src = netip.AddrPortFrom(src.Addr().Unmap(), src.Port())
		pc.WriteToUDPAddrPort(stun.Response(txid, src), src)
	}
}

func check(err error) {
	if err != nil {
		log.Fatal(err)
	}
}
