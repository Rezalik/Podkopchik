//go:build linux

package dokodemo

import (
	"fmt"
	"net"
	"os"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/buf"
	xnet "github.com/xtls/xray-core/common/net"
)

func probeFDCount(t *testing.T) int {
	t.Helper()
	files, err := os.ReadDir("/proc/self/fd")
	if err != nil {
		t.Fatal(err)
	}
	return len(files)
}

// Loopback-only kernel sockets exercise the real PacketWriter/FakeUDP path.
// No nft rule, route, interface, DNS setting or production Xray is changed.
func TestPodkopchikUDPChurn(t *testing.T) {
	if os.Geteuid() != 0 || os.Getenv("PODKOPCHIK_LOOPBACK_PROBE") != "1" {
		t.Skip("explicit root loopback probe opt-in required")
	}
	client, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	initial := xnet.UDPDestination(xnet.IPAddress(net.IPv4(127, 64, 0, 1).To4()), 31000)
	conn, err := FakeUDP(&net.UDPAddr{IP: initial.Address.IP(), Port: int(initial.Port)}, 0)
	if err != nil {
		t.Fatal(err)
	}
	before := probeFDCount(t)
	writer := NewPacketWriter(conn, &initial, 0, client.LocalAddr().(*net.UDPAddr))
	defer writer.(*PacketWriter).Close()
	peers := 192
	for round := 0; round < 3; round++ {
		for i := 0; i < peers; i++ {
			peer := round*peers + i
			ip := net.IPv4(127, 64, byte(peer/250), byte(peer%250+1)).To4()
			dest := xnet.UDPDestination(xnet.IPAddress(ip), 31000)
			b := buf.New()
			payload := fmt.Sprintf("probe-%d-%d", round, i)
			b.Write([]byte(payload))
			b.UDP = &dest
			if err := writer.WriteMultiBuffer(buf.MultiBuffer{b}); err != nil {
				t.Fatal(err)
			}
			if err := client.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
				t.Fatal(err)
			}
			packet := make([]byte, 128)
			n, from, err := client.ReadFromUDP(packet)
			if err != nil {
				t.Fatal(err)
			}
			if string(packet[:n]) != payload || !from.IP.Equal(ip) || from.Port != 31000 {
				t.Fatal("full-cone reply payload/source changed")
			}
		}
		t.Logf("round=%d descriptors=%d", round, probeFDCount(t))
	}
	retained := probeFDCount(t) - before
	if os.Getenv("PODKOPCHIK_EXPECT_BOUNDED") == "1" {
		if retained > 128 {
			t.Fatalf("reply cache retained %d extra descriptors; want <=128", retained)
		}
	} else if retained < peers*3-2 {
		t.Fatalf("upstream reproduction did not retain peer sockets: %d", retained)
	}
	// An evicted default socket must be recreated for packets without metadata.
	b := buf.New()
	b.Write([]byte("default-reply"))
	if err := writer.WriteMultiBuffer(buf.MultiBuffer{b}); err != nil {
		t.Fatal(err)
	}
	packet := make([]byte, 64)
	client.SetReadDeadline(time.Now().Add(time.Second))
	n, from, err := client.ReadFromUDP(packet)
	if err != nil || string(packet[:n]) != "default-reply" || !from.IP.Equal(initial.Address.IP()) || from.Port != 31000 {
		t.Fatal("default reply failed after eviction")
	}
	if err := writer.(*PacketWriter).Close(); err != nil {
		t.Fatal(err)
	}
	afterClose := probeFDCount(t)
	if afterClose > before {
		t.Fatalf("writer close leaked descriptors: before=%d after=%d", before, afterClose)
	}
	t.Logf("extra_retained=%d after_close=%d full_cone_replies=%d", retained, afterClose, peers*3)
}
