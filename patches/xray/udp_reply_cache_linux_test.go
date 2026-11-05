//go:build linux

// SPDX-License-Identifier: MPL-2.0

package dokodemo

import (
	"net"
	"os"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/buf"
	xnet "github.com/xtls/xray-core/common/net"
)

// The production 120s timeout is exercised on real sockets while the parent
// writer stays busy with another peer. No shortened production timer is used.
func TestPodkopchikUDPIdle(t *testing.T) {
	if os.Geteuid() != 0 || os.Getenv("PODKOPCHIK_LOOPBACK_PROBE") != "1" {
		t.Skip("explicit root loopback probe opt-in required")
	}
	client, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	cold := xnet.UDPDestination(xnet.IPAddress(net.IPv4(127, 65, 0, 1).To4()), 31001)
	hot := xnet.UDPDestination(xnet.IPAddress(net.IPv4(127, 65, 0, 2).To4()), 31001)
	conn, err := FakeUDP(&net.UDPAddr{IP: cold.Address.IP(), Port: 31001}, 0)
	if err != nil {
		t.Fatal(err)
	}
	w := NewPacketWriter(conn, &cold, 0, client.LocalAddr().(*net.UDPAddr)).(*PacketWriter)
	defer w.Close()
	started := time.Now()
	retired := false
	for time.Since(started) < 165*time.Second {
		b := buf.New()
		b.Write([]byte("keep-parent-active"))
		b.UDP = &hot
		if err := w.WriteMultiBuffer(buf.MultiBuffer{b}); err != nil {
			t.Fatal(err)
		}
		client.SetReadDeadline(time.Now().Add(time.Second))
		packet := make([]byte, 64)
		if _, from, err := client.ReadFromUDP(packet); err != nil || !from.IP.Equal(hot.Address.IP()) {
			t.Fatal("active peer failed")
		}
		w.cache.mu.Lock()
		_, exists := w.cache.entries[cold]
		n := len(w.cache.entries)
		w.cache.mu.Unlock()
		if !exists {
			if time.Since(started) < udpReplyIdle || n != 1 {
				t.Fatal("unexpected idle retirement")
			}
			retired = true
			break
		}
		time.Sleep(time.Second)
	}
	if !retired {
		t.Fatal("cold reply socket retained by active full-cone parent")
	}
	// No UDP metadata means the original/default source address must be recreated.
	b := buf.New()
	b.Write([]byte("default-after-idle"))
	if err := w.WriteMultiBuffer(buf.MultiBuffer{b}); err != nil {
		t.Fatal(err)
	}
	client.SetReadDeadline(time.Now().Add(time.Second))
	packet := make([]byte, 64)
	n, from, err := client.ReadFromUDP(packet)
	if err != nil || string(packet[:n]) != "default-after-idle" || !from.IP.Equal(cold.Address.IP()) {
		t.Fatal("default source not recreated after idle expiry")
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	t.Logf("idle_retired_seconds=%.1f descriptors_after_close=%d full_cone_parent_stayed_active=true", time.Since(started).Seconds(), probeFDCount(t))
}
