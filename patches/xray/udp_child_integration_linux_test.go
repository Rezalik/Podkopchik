//go:build linux

// SPDX-License-Identifier: MPL-2.0

package dokodemo

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/miekg/dns"
	"golang.org/x/net/proxy"
)

func labOwnsPort(pid, port int, network string) bool {
	owned := map[string]bool{}
	fds, _ := os.ReadDir(fmt.Sprintf("/proc/%d/fd", pid))
	for _, fd := range fds {
		target, _ := os.Readlink(fmt.Sprintf("/proc/%d/fd/%s", pid, fd.Name()))
		if strings.HasPrefix(target, "socket:[") {
			owned[strings.TrimSuffix(strings.TrimPrefix(target, "socket:["), "]")] = true
		}
	}
	for _, family := range []string{network, network + "6"} {
		data, _ := os.ReadFile(fmt.Sprintf("/proc/%d/net/%s", pid, family))
		for _, line := range strings.Split(string(data), "\n")[1:] {
			a := strings.Fields(line)
			if len(a) > 9 && owned[a[9]] && strings.HasSuffix(a[1], fmt.Sprintf(":%04X", port)) && (network != "tcp" || a[3] == "0A") {
				return true
			}
		}
	}
	return false
}

// A separate core uses current AWG outbounds/rules with loopback-only listeners.
// Pdeathsig and CommandContext terminate it independently of SSH/test failure.
func TestPodkopchikIsolatedFeatures(t *testing.T) {
	if os.Geteuid() != 0 || os.Getenv("PODKOPCHIK_LOOPBACK_PROBE") != "1" {
		t.Skip("explicit root loopback probe opt-in required")
	}
	board, _ := os.ReadFile("/tmp/sysinfo/board_name")
	if strings.TrimSpace(string(board)) != "xiaomi,redmi-router-ax6000-stock" {
		t.Fatal("wrong board")
	}
	core := os.Getenv("PODKOPCHIK_LAB_CORE")
	if !strings.HasPrefix(core, "/tmp/podkopchik-udp-lab-") || filepath.Base(core) != "xray" {
		t.Fatal("private temporary core path required")
	}
	raw, err := os.ReadFile("/etc/podkopchik/config.json")
	if err != nil {
		t.Fatal("cannot read active config")
	}
	var config map[string]any
	if json.Unmarshal(raw, &config) != nil {
		t.Fatal("cannot decode active config")
	}
	outbounds, ok := config["outbounds"].([]any)
	if !ok {
		t.Fatal("missing outbounds")
	}
	var awg []string
	for _, item := range outbounds {
		o := item.(map[string]any)
		p, _ := o["protocol"].(string)
		if p != "freedom" && p != "blackhole" && p != "dns" {
			t.Fatal("AWG-only fixture required; no private proxy data is copied")
		}
		if strings.HasPrefix(fmt.Sprint(o["tag"]), "awg_") && p == "freedom" {
			awg = append(awg, fmt.Sprint(o["tag"]))
		}
	}
	if len(awg) == 0 {
		t.Fatal("no running AWG outbound available")
	}
	dir, err := os.MkdirTemp(filepath.Dir(core), "child-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	var reservations []net.Listener
	port := func() int {
		l, e := net.Listen("tcp4", "127.0.0.1:0")
		if e != nil {
			t.Fatal(e)
		}
		reservations = append(reservations, l)
		return l.Addr().(*net.TCPAddr).Port
	}
	defer func() {
		for _, l := range reservations {
			l.Close()
		}
	}()
	mainPort, fakePort, blockedPort := port(), port(), port()
	dnsPort, apiPort := port(), port()
	sniff := map[string]any{"enabled": true, "destOverride": []string{"http", "tls", "quic", "fakedns"}, "routeOnly": false}
	inbound := func(tag string, p int, s any) map[string]any {
		return map[string]any{"tag": tag, "listen": "127.0.0.1", "port": p, "protocol": "socks", "settings": map[string]any{"auth": "noauth", "udp": false}, "sniffing": s}
	}
	inbounds := []any{inbound("podkopchik-lab", mainPort, sniff), inbound("podkopchik-lab-fake", fakePort, map[string]any{"enabled": true, "metadataOnly": true, "destOverride": []string{"fakedns"}}), inbound("podkopchik-lab-blocked", blockedPort, nil),
		map[string]any{"tag": "dns-in", "listen": "127.0.0.1", "port": dnsPort, "protocol": "dokodemo-door", "settings": map[string]any{"network": "tcp,udp", "address": "8.8.8.8", "port": 53}},
		map[string]any{"tag": "podkopchik-api-in", "listen": "127.0.0.1", "port": apiPort, "protocol": "dokodemo-door", "settings": map[string]any{"network": "tcp", "address": "127.0.0.1"}}}
	routing := config["routing"].(map[string]any)
	rules := []any{map[string]any{"type": "field", "inboundTag": []string{"podkopchik-lab-blocked"}, "outboundTag": "blocked"}}
	var awgPorts []int
	for i, tag := range awg {
		p := port()
		awgPorts = append(awgPorts, p)
		name := fmt.Sprintf("podkopchik-lab-awg-%d", i)
		inbounds = append(inbounds, inbound(name, p, nil))
		rules = append(rules, map[string]any{"type": "field", "inboundTag": []string{name}, "outboundTag": tag})
	}
	rules = append(rules, routing["rules"].([]any)...)
	routing["rules"] = rules
	config["inbounds"] = inbounds
	access := filepath.Join(dir, "access.log")
	if err := os.WriteFile(access, nil, 0600); err != nil {
		t.Fatal(err)
	}
	config["log"] = map[string]any{"loglevel": "warning", "access": access}
	encoded, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(dir, "config.json")
	if os.WriteFile(configPath, encoded, 0600) != nil {
		t.Fatal("cannot write private fixture")
	}
	for _, l := range reservations {
		l.Close()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Second)
	defer cancel()
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	cmd := exec.CommandContext(ctx, core, "run", "-config", configPath)
	cmd.Env = append(os.Environ(), "XRAY_CONE_DISABLED=false", "xray.cone.disabled=false")
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
	log, err := os.OpenFile(filepath.Join(dir, "core.log"), os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer log.Close()
	cmd.Stdout = log
	cmd.Stderr = log
	if err := cmd.Start(); err != nil {
		t.Fatal("cannot start isolated core")
	}
	defer func() { cmd.Process.Kill(); cmd.Wait() }()
	ready := false
	for i := 0; i < 40; i++ {
		allTCP := true
		for _, p := range append([]int{mainPort, fakePort, blockedPort, dnsPort, apiPort}, awgPorts...) {
			if !labOwnsPort(cmd.Process.Pid, p, "tcp") {
				allTCP = false
			}
		}
		if allTCP && labOwnsPort(cmd.Process.Pid, dnsPort, "udp") {
			ready = true
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !ready {
		t.Fatal("isolated process does not own the probe listeners")
	}
	query := func(name, network string) string {
		m := new(dns.Msg)
		m.SetQuestion(dns.Fqdn(name), dns.TypeA)
		c := dns.Client{Net: network, Timeout: 3 * time.Second}
		r, _, e := c.Exchange(m, fmt.Sprintf("127.0.0.1:%d", dnsPort))
		if e != nil {
			t.Fatal("isolated DNS query failed")
		}
		for _, rr := range r.Answer {
			if a, ok := rr.(*dns.A); ok && a.A.To4() != nil {
				v := a.A.To4()
				if v[0] == 198 && (v[1] == 18 || v[1] == 19) {
					return a.A.String()
				}
			}
		}
		t.Fatal("isolated DNS did not return a fake IPv4")
		return ""
	}
	query("x.com", "udp")
	query("x.com", "tcp")
	t.Log("DNS UDP/TCP and FakeDNS: PASS")
	request := func(p int, url, connect string) (string, error) {
		args := []string{"--silent", "--show-error", "--noproxy", "", "--proxy", fmt.Sprintf("socks5h://127.0.0.1:%d", p), "--connect-timeout", "5", "--max-time", "12", "-o", "/dev/null", "-w", "%{http_code}"}
		if strings.Contains(url, "/cdn-cgi/trace") {
			args = append(args, "--max-filesize", "4096")
		} else {
			args = append(args, "--head")
		}
		if connect != "" {
			args = append(args, "--connect-to", connect)
		}
		args = append(args, url)
		rctx, stop := context.WithTimeout(ctx, 14*time.Second)
		defer stop()
		c := exec.CommandContext(rctx, "curl", args...)
		data, e := c.Output()
		return strings.TrimSpace(string(data)), e
	}
	for _, service := range []struct{ name, url string }{{"YouTube", "https://www.youtube.com/"}, {"Instagram", "https://www.instagram.com/"}, {"Telegram web", "https://telegram.org/"}} {
		code, e := request(mainPort, service.url, "")
		if e != nil {
			t.Errorf("%s isolated HTTPS failed (response=%s)", service.name, code)
		} else {
			t.Logf("%s HTTPS status=%s (transport only, not authenticated app/video)", service.name, code)
		}
	}
	for i, p := range awgPorts {
		code, e := request(p, "https://one.one.one.one/cdn-cgi/trace", "one.one.one.one:443:1.1.1.1:443")
		if e != nil || code != "200" {
			t.Errorf("AWG outbound %d pinned HTTPS failed (status=%s error=%v)", i+1, code, e)
		} else {
			t.Logf("AWG outbound %d pinned HTTPS: PASS", i+1)
		}
	}
	fake := query("www.youtube.com", "udp")
	code, e := request(fakePort, "https://www.youtube.com/", "www.youtube.com:443:"+fake+":443")
	if e != nil {
		t.Error("FakeDNS metadata-only HTTPS failed")
	} else {
		t.Logf("FakeDNS without TLS/domain sniffing HTTPS status=%s: PASS", code)
	}
	if ctx.Err() != nil {
		t.Fatal("isolated test time budget exhausted")
	}
	if _, e := request(blockedPort, "https://1.1.1.1/", ""); e == nil {
		t.Error("isolated blackhole target did not block HTTPS")
	} else {
		t.Log("Isolated blocked outbound: PASS (not AWG-down WAN capture)")
	}
	dialer, e := proxy.SOCKS5("tcp", fmt.Sprintf("127.0.0.1:%d", mainPort), nil, &net.Dialer{Timeout: 5 * time.Second})
	if e != nil {
		t.Fatal(e)
	}
	dctx, stop := context.WithTimeout(ctx, 6*time.Second)
	conn, e := dialer.(proxy.ContextDialer).DialContext(dctx, "tcp", "149.154.167.41:443")
	stop()
	if e == nil {
		conn.Close()
		t.Log("Telegram IP TCP connect: PASS (not authenticated Telegram)")
	} else {
		t.Log("Telegram IP TCP connect: SKIPPED, endpoint unavailable within bounded probe")
	}
	data, _ := os.ReadFile(access)
	matches := regexp.MustCompile(`\[podkopchik-lab(?:-fake)?\s+(?:->|>>)\s+(awg_[a-f0-9]+|direct|blocked)\]`).FindAllStringSubmatch(string(data), -1)
	counts := map[string]int{}
	for _, m := range matches {
		kind := m[1]
		if strings.HasPrefix(kind, "awg_") {
			kind = "awg"
		}
		counts[kind]++
	}
	if counts["awg"] == 0 {
		t.Error("isolated domain traffic had no AWG access record")
	}
	t.Logf("isolated domain access categories=%v", counts)
	t.Log("SKIPPED: authenticated apps/video, QUIC/HTTP3, real LAN source rules, production failover/AWG-down WAN capture, multi-hour load")
	t.Logf("isolated child descriptors=%s", strconv.Itoa(func() int { fds, _ := os.ReadDir(fmt.Sprintf("/proc/%d/fd", cmd.Process.Pid)); return len(fds) }()))
}
