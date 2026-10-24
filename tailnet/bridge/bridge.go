// Package bridge embeds a Tailscale node (tsnet) in a Nearclip app and connects it to the
// app's native engine through two loopback sockets, so the Swift, Kotlin and C# engines keep
// using their ordinary TCP code:
//
//   - Inbound: tailnet TCP connections to the node's Nearclip ports are forwarded to the
//     engine's loopback listener (Config.Forward).
//   - Outbound: the engine connects to 127.0.0.1:<proxyPort> and sends one line
//     "NCTN1 <token> <tailnet-ip>:<port>\n". The bridge answers a single status byte
//     (0 = connected; 1 = bad request; 2 = dial failed; 3 = not running) and then relays
//     bytes in both directions.
//
// All Nearclip traffic stays end-to-end encrypted by the Nearclip protocol itself; Tailscale
// only provides reachability (WireGuard, NAT traversal, DERP fallback).
//
// Status is read through tsnet's in-memory LocalAPI client, never through a loopback socket:
// iOS reclaims listening sockets of suspended apps (tailscale/tailscale#20060), so the apps
// stop the node before suspension and start a fresh one when they become active again.
package bridge

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/netip"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/envknob"
	"tailscale.com/hostinfo"
	"tailscale.com/ipn"
	"tailscale.com/net/netns"
	"tailscale.com/net/tsaddr"
	"tailscale.com/tsnet"
	"tailscale.com/types/logger"
	"tailscale.com/version"
)

// DefaultPort is the tailnet TCP port every Nearclip node listens on, regardless of the port its
// LAN listener got. Peers found through the tailnet are dialed here.
const DefaultPort = 45821

// Proxy status bytes.
const (
	ProxyOK         = 0
	ProxyBadRequest = 1
	ProxyDialFailed = 2
	ProxyNotRunning = 3
)

// Config is the JSON object passed to Start.
type Config struct {
	// Dir keeps the node's state (keys, login). Required. Exclude it from backups.
	Dir string `json:"dir"`
	// DeviceID and DeviceName build the node's hostname, nearclip-<name>-<id8>.
	DeviceID   string `json:"deviceId"`
	DeviceName string `json:"deviceName"`
	// Ports are the tailnet TCP ports to accept Nearclip connections on (DefaultPort is always added).
	Ports []int `json:"ports,omitempty"`
	// Forward is the engine's loopback listener, e.g. "127.0.0.1:50123". Required.
	Forward string `json:"forward"`
	// ControlURL, AuthKey and Ephemeral are for tests and self-hosted control servers.
	ControlURL string `json:"controlURL,omitempty"`
	AuthKey    string `json:"authKey,omitempty"`
	Ephemeral  bool   `json:"ephemeral,omitempty"`
	// LogPath receives verbose backend logs ("-" = stderr). Empty discards them.
	LogPath string `json:"logPath,omitempty"`
	// TestMode disables socket binding to the default interface (needed for loopback control servers).
	TestMode bool `json:"testMode,omitempty"`
}

// Peer is another Nearclip node in the same tailnet.
type Peer struct {
	Host     string `json:"host"`
	IDPrefix string `json:"idPrefix,omitempty"` // first 8 hex digits of its Nearclip device id
	IP       string `json:"ip"`
	Online   bool   `json:"online"`
	OS       string `json:"os,omitempty"`
	Direct   bool   `json:"direct"`          // a direct WireGuard path is in use
	Relay    string `json:"relay,omitempty"` // DERP region used as fallback
}

// Status is returned (as JSON) by every API call.
type Status struct {
	// State is one of: off, starting, needsLogin, needsApproval, running, stopped, error.
	State     string   `json:"state"`
	Backend   string   `json:"backend,omitempty"`
	AuthURL   string   `json:"authURL,omitempty"`
	IP        string   `json:"ip,omitempty"`
	IP6       string   `json:"ip6,omitempty"`
	Hostname  string   `json:"hostname,omitempty"`
	DNSName   string   `json:"dnsName,omitempty"`
	Account   string   `json:"account,omitempty"`
	Tailnet   string   `json:"tailnet,omitempty"`
	ProxyPort int      `json:"proxyPort,omitempty"`
	Token     string   `json:"token,omitempty"`
	Ports     []int    `json:"ports,omitempty"`
	Peers     []Peer   `json:"peers"`
	Health    []string `json:"health,omitempty"`
	Error     string   `json:"error,omitempty"`
	Version   string   `json:"version"`
}

type bridge struct {
	cfg       Config
	cfgKey    string
	srv       *tsnet.Server
	lc        *local.Client
	ctx       context.Context
	cancel    context.CancelFunc
	token     string
	proxy     net.Listener
	proxyPort int
	ports     []int
	lns       []net.Listener
	hostname  string
	closeLog  func()
	logf      logger.Logf
}

var (
	lifecycle sync.Mutex // serializes Start and Stop
	mu        sync.Mutex // guards cur
	cur       *bridge
)

func current() *bridge {
	mu.Lock()
	defer mu.Unlock()
	return cur
}

func offStatus() Status {
	return Status{State: "off", Peers: []Peer{}, Version: tsVersion()}
}

func tsVersion() string {
	v := version.Short()
	if i := strings.Index(v, "-ERR"); i > 0 {
		v = v[:i]
	}
	return v
}

func errStatus(err error) Status {
	s := offStatus()
	s.State = "error"
	s.Error = err.Error()
	return s
}

// Start starts the node (or returns the status of the one already running with the same config).
// It does not wait for login; poll Status.
func Start(cfg Config) Status {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	key, _ := json.Marshal(cfg)
	if b := current(); b != nil {
		if b.cfgKey == string(key) {
			return b.status(3 * time.Second)
		}
		mu.Lock()
		cur = nil
		mu.Unlock()
		b.close()
	}
	b, err := start(cfg)
	if err != nil {
		return errStatus(err)
	}
	b.cfgKey = string(key)
	mu.Lock()
	cur = b
	mu.Unlock()
	return b.status(3 * time.Second)
}

// Stop shuts the node down. Its login is kept in Config.Dir.
func Stop() Status {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	mu.Lock()
	b := cur
	cur = nil
	mu.Unlock()
	if b != nil {
		b.close()
	}
	return offStatus()
}

// CurrentStatus reports the node's state, its tailnet address and the other Nearclip nodes.
func CurrentStatus() Status {
	b := current()
	if b == nil {
		return offStatus()
	}
	return b.status(3 * time.Second)
}

// Login starts an interactive login (if needed) and waits up to 15 s for the login URL.
func Login() Status {
	b := current()
	if b == nil {
		return errStatus(errors.New("not started"))
	}
	ctx, cancel := context.WithTimeout(b.ctx, 20*time.Second)
	defer cancel()
	if st, err := b.lc.StatusWithoutPeers(ctx); err == nil {
		if st.BackendState == ipn.Running.String() {
			return b.status(3 * time.Second)
		}
		if st.AuthURL != "" {
			return b.status(3 * time.Second)
		}
	}
	if err := b.lc.StartLoginInteractive(ctx); err != nil {
		s := b.status(3 * time.Second)
		s.Error = err.Error()
		return s
	}
	deadline := time.Now().Add(15 * time.Second)
	for {
		s := b.status(3 * time.Second)
		if s.AuthURL != "" || s.State == "running" || time.Now().After(deadline) || ctx.Err() != nil {
			return s
		}
		time.Sleep(250 * time.Millisecond)
	}
}

// Logout signs this node out of the tailnet (the node then needs a new login).
func Logout() Status {
	b := current()
	if b == nil {
		return errStatus(errors.New("not started"))
	}
	ctx, cancel := context.WithTimeout(b.ctx, 15*time.Second)
	defer cancel()
	err := b.lc.Logout(ctx)
	s := b.status(3 * time.Second)
	if err != nil {
		s.Error = err.Error()
	}
	return s
}

// NetworkChanged tells the node that the device's network changed (it re-binds sockets and
// re-discovers paths). Android must call SetNetwork instead/as well (see network_android.go).
func NetworkChanged() {
	if b := current(); b != nil {
		if sys := b.srv.Sys(); sys != nil {
			if nm, ok := sys.NetMon.GetOK(); ok && nm != nil {
				nm.InjectEvent()
			}
		}
	}
}

func start(cfg Config) (*bridge, error) {
	if cfg.Dir == "" || cfg.Forward == "" {
		return nil, errors.New("dir and forward are required")
	}
	if _, err := netip.ParseAddrPort(cfg.Forward); err != nil {
		return nil, fmt.Errorf("bad forward address %q", cfg.Forward)
	}
	if err := os.MkdirAll(cfg.Dir, 0o700); err != nil {
		return nil, err
	}
	// Diagnostic logs stay on the device: nothing is uploaded to log.tailscale.com.
	envknob.Setenv("TS_NO_LOGS_NO_SUPPORT", "true")
	if cfg.TestMode {
		netns.SetEnabled(false)
	}
	hostinfo.SetApp("nearclip")
	installPlatformHooks()

	logf, closeLog := openLog(cfg.LogPath)
	hostname := MakeHostname(cfg.DeviceName, cfg.DeviceID)
	srv := &tsnet.Server{
		Dir:        cfg.Dir,
		Hostname:   hostname,
		ControlURL: cfg.ControlURL,
		AuthKey:    cfg.AuthKey,
		Ephemeral:  cfg.Ephemeral,
		Logf:       logf,
		UserLogf:   logf,
	}
	fail := func(err error) (*bridge, error) {
		srv.Close()
		closeLog()
		return nil, err
	}
	if err := srv.Start(); err != nil {
		return fail(err)
	}
	lc, err := srv.LocalClient()
	if err != nil {
		return fail(err)
	}
	ports := uniquePorts(append([]int{DefaultPort}, cfg.Ports...))
	var lns []net.Listener
	closeAll := func() {
		for _, ln := range lns {
			ln.Close()
		}
	}
	for _, p := range ports {
		ln, err := srv.Listen("tcp", fmt.Sprintf(":%d", p))
		if err != nil {
			closeAll()
			return fail(fmt.Errorf("listen on tailnet port %d: %w", p, err))
		}
		lns = append(lns, ln)
	}
	pl, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		closeAll()
		return fail(err)
	}
	var tok [16]byte
	if _, err := rand.Read(tok[:]); err != nil {
		pl.Close()
		closeAll()
		return fail(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	b := &bridge{
		cfg:       cfg,
		srv:       srv,
		lc:        lc,
		ctx:       ctx,
		cancel:    cancel,
		token:     hex.EncodeToString(tok[:]),
		proxy:     pl,
		proxyPort: pl.Addr().(*net.TCPAddr).Port,
		ports:     ports,
		lns:       lns,
		hostname:  hostname,
		closeLog:  closeLog,
		logf:      logf,
	}
	go b.serveProxy()
	for _, ln := range lns {
		go b.serveTailnet(ln)
	}
	logf("nearclip bridge: started %s, proxy 127.0.0.1:%d, tailnet ports %v -> %s", hostname, b.proxyPort, ports, cfg.Forward)
	return b, nil
}

func (b *bridge) close() {
	b.cancel()
	b.proxy.Close()
	for _, ln := range b.lns {
		ln.Close()
	}
	done := make(chan struct{})
	go func() {
		b.srv.Close()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(8 * time.Second):
		b.logf("nearclip bridge: tsnet close timed out")
	}
	b.closeLog()
}

func (b *bridge) status(timeout time.Duration) Status {
	out := Status{
		State:     "starting",
		Hostname:  b.hostname,
		ProxyPort: b.proxyPort,
		Token:     b.token,
		Ports:     b.ports,
		Peers:     []Peer{},
		Version:   tsVersion(),
	}
	ctx, cancel := context.WithTimeout(b.ctx, timeout)
	defer cancel()
	st, err := b.lc.Status(ctx)
	if err != nil {
		out.Error = err.Error()
		return out
	}
	out.Backend = st.BackendState
	switch st.BackendState {
	case ipn.Running.String():
		out.State = "running"
	case ipn.NeedsLogin.String():
		out.State = "needsLogin"
	case ipn.NeedsMachineAuth.String():
		out.State = "needsApproval"
	case ipn.Stopped.String():
		out.State = "stopped"
	}
	if out.State != "running" {
		out.AuthURL = st.AuthURL
	}
	for _, ip := range st.TailscaleIPs {
		if ip.Is4() && out.IP == "" {
			out.IP = ip.String()
		} else if ip.Is6() && out.IP6 == "" {
			out.IP6 = ip.String()
		}
	}
	if st.Self != nil {
		out.DNSName = strings.TrimSuffix(st.Self.DNSName, ".")
		if u, ok := st.User[st.Self.UserID]; ok {
			out.Account = u.LoginName
		}
	}
	if st.CurrentTailnet != nil {
		out.Tailnet = st.CurrentTailnet.Name
	}
	out.Health = st.Health
	for _, ps := range st.Peer {
		if ps == nil || !strings.HasPrefix(ps.HostName, HostPrefix) {
			continue
		}
		p := Peer{
			Host:     ps.HostName,
			IDPrefix: ParseIDPrefix(ps.HostName),
			Online:   ps.Online,
			OS:       ps.OS,
			Direct:   ps.CurAddr != "",
			Relay:    ps.Relay,
		}
		for _, ip := range ps.TailscaleIPs {
			if ip.Is4() {
				p.IP = ip.String()
				break
			}
		}
		if p.IP != "" {
			out.Peers = append(out.Peers, p)
		}
	}
	sort.Slice(out.Peers, func(i, j int) bool { return out.Peers[i].Host < out.Peers[j].Host })
	return out
}

func (b *bridge) running(ctx context.Context) bool {
	st, err := b.lc.StatusWithoutPeers(ctx)
	return err == nil && st.BackendState == ipn.Running.String()
}

// MARK: - Inbound (tailnet -> engine)

func (b *bridge) serveTailnet(ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go b.forwardIn(c)
	}
}

func (b *bridge) forwardIn(c net.Conn) {
	defer c.Close()
	d := net.Dialer{Timeout: 3 * time.Second}
	l, err := d.DialContext(b.ctx, "tcp", b.cfg.Forward)
	if err != nil {
		b.logf("nearclip bridge: forward to engine failed: %v", err)
		return
	}
	defer l.Close()
	splice(c, l)
}

// MARK: - Outbound proxy (engine -> tailnet)

func (b *bridge) serveProxy() {
	for {
		c, err := b.proxy.Accept()
		if err != nil {
			return
		}
		go b.handleProxy(c)
	}
}

func (b *bridge) handleProxy(c net.Conn) {
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	line, err := readLine(c, 300)
	if err != nil {
		return
	}
	f := strings.Fields(line)
	if len(f) != 3 || f[0] != "NCTN1" || subtle.ConstantTimeCompare([]byte(f[1]), []byte(b.token)) != 1 {
		c.Write([]byte{ProxyBadRequest})
		return
	}
	ap, err := netip.ParseAddrPort(f[2])
	if err != nil || !tsaddr.IsTailscaleIP(ap.Addr()) {
		// Only tailnet addresses: the bridge is not a general-purpose proxy.
		c.Write([]byte{ProxyBadRequest})
		return
	}
	ctx, cancel := context.WithTimeout(b.ctx, 12*time.Second)
	defer cancel()
	if !b.running(ctx) {
		c.Write([]byte{ProxyNotRunning})
		return
	}
	c.SetDeadline(time.Now().Add(13 * time.Second))
	t, err := b.srv.Dial(ctx, "tcp", ap.String())
	if err != nil {
		b.logf("nearclip bridge: dial %v: %v", ap, err)
		c.Write([]byte{ProxyDialFailed})
		return
	}
	defer t.Close()
	c.SetDeadline(time.Time{})
	if _, err := c.Write([]byte{ProxyOK}); err != nil {
		return
	}
	splice(c, t)
}

// readLine reads up to '\n' one byte at a time so no stream bytes are consumed past it.
func readLine(r io.Reader, max int) (string, error) {
	var buf []byte
	var one [1]byte
	for len(buf) < max {
		if _, err := io.ReadFull(r, one[:]); err != nil {
			return "", err
		}
		if one[0] == '\n' {
			return strings.TrimRight(string(buf), "\r"), nil
		}
		buf = append(buf, one[0])
	}
	return "", errors.New("line too long")
}

// splice relays bytes both ways until one side is done, then closes both.
func splice(a, b net.Conn) {
	done := make(chan struct{}, 2)
	cp := func(dst, src net.Conn) {
		io.Copy(dst, src)
		if cw, ok := dst.(interface{ CloseWrite() error }); ok {
			cw.CloseWrite()
		} else {
			dst.Close()
		}
		done <- struct{}{}
	}
	go cp(a, b)
	go cp(b, a)
	<-done
	select {
	case <-done:
	case <-time.After(2 * time.Second):
	}
	a.Close()
	b.Close()
}

func uniquePorts(ps []int) []int {
	seen := map[int]bool{}
	var out []int
	for _, p := range ps {
		if p > 0 && p < 65536 && !seen[p] {
			seen[p] = true
			out = append(out, p)
		}
	}
	return out
}

func openLog(path string) (logger.Logf, func()) {
	switch path {
	case "":
		return logger.Discard, func() {}
	case "-":
		l := log.New(os.Stderr, "tailnet: ", log.LstdFlags|log.Lmicroseconds)
		return l.Printf, func() {}
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return logger.Discard, func() {}
	}
	if fi, err := f.Stat(); err == nil && fi.Size() > 4<<20 {
		f.Truncate(0)
	}
	l := log.New(f, "", log.LstdFlags|log.Lmicroseconds)
	return l.Printf, func() { f.Close() }
}
