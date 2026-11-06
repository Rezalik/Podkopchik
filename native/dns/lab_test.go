package main

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"testing"

	"github.com/miekg/dns"
	"golang.org/x/net/proxy"
)

// Only the isolated VM shell harness invokes these synthetic network fixtures.
func TestGuestFixture(t *testing.T) {
	mode := os.Getenv("PKC_NATIVE_LAB")
	if mode == "" {
		t.Skip("VM fixture only")
	}
	if len(os.Args) < 4 || os.Args[2] != "--" {
		t.Fatal("fixture argument mismatch")
	}
	a := os.Args[3:]
	switch mode {
	case "dns":
		h := dns.HandlerFunc(func(w dns.ResponseWriter, q *dns.Msg) {
			m := new(dns.Msg).SetReply(q)
			name := q.Question[0].Name
			if q.Question[0].Qtype == dns.TypeAAAA {
				m.Answer = []dns.RR{rr(name + " 2 IN AAAA 2001:db8:80::1")}
			} else if name == "protected.example." || name == "expire.protected.example." {
				m.Answer = []dns.RR{rr(name + " 2 IN CNAME cdn.example."), rr("cdn.example. 90 IN A 203.0.113.80")}
			} else if name == "multiple.protected.example." {
				m.Answer = []dns.RR{rr(name + " 90 IN A 203.0.113.90"), rr(name + " 90 IN A 203.0.113.91")}
			} else {
				m.Answer = []dns.RR{rr(name + " 90 IN A 203.0.113.80")}
			}
			_ = w.WriteMsg(m)
		})
		t.Fatal(dns.ListenAndServe(a[0], a[1], h))
	case "query":
		qt := dns.StringToType[a[3]]
		count, err := strconv.Atoi(a[5])
		if err != nil {
			t.Fatal(err)
		}
		m := requireAnswer(t, a[0], a[1], a[2], qt, dns.StringToRcode[a[4]], count)
		for _, record := range m.Answer {
			switch x := record.(type) {
			case *dns.A:
				fmt.Println("address=" + x.A.String())
			case *dns.AAAA:
				fmt.Println("address=" + x.AAAA.String())
			case *dns.PTR:
				fmt.Println("name=" + x.Ptr)
			default:
				t.Fatal("unflattened DNS response")
			}
		}
	case "soak":
		seconds, err := strconv.Atoi(a[1])
		if err != nil || seconds < 10 || seconds > 600 {
			t.Fatal("invalid soak duration")
		}
		until := time.Now().Add(time.Duration(seconds) * time.Second)
		var wg sync.WaitGroup
		var count atomic.Int64
		for worker := range 4 {
			wg.Go(func() {
				proto := []string{"udp", "tcp"}[worker%2]
				qt := []uint16{dns.TypeA, dns.TypeAAAA}[worker/2]
				for time.Now().Before(until) {
					m, err := exchange(a[0], proto, "protected.example.", qt)
					if err != nil || m.Rcode != dns.RcodeSuccess || len(m.Answer) != 1 {
						t.Error("protected DNS failed during soak", err)
						return
					}
					switch rr := m.Answer[0].(type) {
					case *dns.A:
						if v := rr.A.To4(); v == nil || v[0] != 172 || v[1] != 31 || v[2] != 253 {
							t.Error("unexpected IPv4 during soak")
							return
						}
					case *dns.AAAA:
						if v := rr.AAAA; len(v) != 16 || v[0] != 0x20 || v[1] != 1 || v[2] != 0 || v[3] != 2 {
							t.Error("unexpected IPv6 during soak")
							return
						}
					default:
						t.Error("unexpected RR type during soak")
						return
					}
					count.Add(1)
					time.Sleep(250 * time.Millisecond)
				}
			})
		}
		wg.Wait()
		if count.Load() < int64(seconds)*4 {
			t.Fatal("insufficient queries during soak", count.Load())
		}
		fmt.Printf("soak_seconds=%d successful_queries=%d\n", seconds, count.Load())
	case "no-dns":
		c := dns.Client{Net: a[1], Timeout: time.Second}
		if m, _, err := c.Exchange(new(dns.Msg).SetQuestion(a[2], dns.TypeA), a[0]); err == nil {
			t.Fatalf("unexpected DNS reply: %v", m)
		}
	case "serve":
		ln, err := net.Listen("tcp", a[0])
		if err != nil {
			t.Fatal(err)
		}
		go func() {
			_ = http.Serve(ln, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				_, _ = w.Write([]byte("isolated-http-ok"))
			}))
		}()
		pc, err := net.ListenPacket("udp", a[0])
		if err != nil {
			t.Fatal(err)
		}
		for {
			var payload [32]byte
			n, src, e := pc.ReadFrom(payload[:])
			if e != nil {
				t.Fatal(e)
			}
			if string(payload[:n]) == "isolated-udp" {
				_, _ = pc.WriteTo([]byte("isolated-udp-ok"), src)
			}
		}
	case "udp":
		c, err := net.Dial("udp", a[0])
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
		_ = c.SetDeadline(time.Now().Add(time.Second))
		_, _ = c.Write([]byte("isolated-udp"))
		var b [32]byte
		n, err := c.Read(b[:])
		if err != nil || string(b[:n]) != "isolated-udp-ok" {
			t.Fatal("UDP echo missing", err)
		}
	case "dial":
		d := net.Dialer{Timeout: time.Second}
		if len(a) > 1 {
			ip := net.ParseIP(a[1])
			if ip == nil {
				t.Fatal("invalid source address")
			}
			d.LocalAddr = &net.TCPAddr{IP: ip}
		}
		c, err := d.Dial("tcp", a[0])
		if err != nil {
			t.Fatal("TCP connect failed", err)
		}
		_ = c.Close()
	case "quic-serve", "quic-client":
		if err := quicFixture(mode, a[0], a[1]); err != nil {
			t.Fatal(err)
		}
	case "socks":
		d, err := proxy.SOCKS5("tcp", a[0], nil, &net.Dialer{Timeout: 2 * time.Second})
		if err != nil {
			t.Fatal(err)
		}
		c, err := d.Dial("tcp", a[1])
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
		_ = c.SetDeadline(time.Now().Add(2 * time.Second))
		_, _ = fmt.Fprint(c, "GET / HTTP/1.1\r\nHost: fixture.example\r\nConnection: close\r\n\r\n")
		line, err := bufio.NewReader(c).ReadString('\n')
		if err != nil || line != "HTTP/1.1 200 OK\r\n" {
			t.Fatal("VLESS transport fixture did not return HTTP 200", err)
		}
	case "hold":
		c, err := net.DialTimeout("tcp", a[0], 2*time.Second)
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
		b := bufio.NewReader(c)
		get := func() error {
			_ = c.SetDeadline(time.Now().Add(2 * time.Second))
			if _, e := fmt.Fprint(c, "GET / HTTP/1.1\r\nHost: fixture.example\r\n\r\n"); e != nil {
				return e
			}
			res, e := http.ReadResponse(b, nil)
			if e != nil {
				return e
			}
			defer res.Body.Close()
			body, e := io.ReadAll(res.Body)
			if e != nil || res.StatusCode != 200 || string(body) != "isolated-http-ok" {
				return fmt.Errorf("unexpected HTTP payload")
			}
			return nil
		}
		if e := get(); e != nil {
			t.Fatal(e)
		}
		if e := os.WriteFile(a[1], []byte("ready"), 0600); e != nil {
			t.Fatal(e)
		}
		wait := 10 * time.Second
		if len(a) > 3 && a[3] == "expire" {
			wait = 45 * time.Second
		}
		for until := time.Now().Add(wait); time.Now().Before(until); {
			if _, e := os.Stat(a[2] + ".again"); e == nil {
				if _, e := os.Stat(a[2] + ".replied"); os.IsNotExist(e) {
					if e := get(); e != nil {
						t.Fatal("established flow failed without changing its transport", e)
					}
					if e := os.WriteFile(a[2]+".replied", nil, 0600); e != nil {
						t.Fatal(e)
					}
				}
			}
			if _, e := os.Stat(a[2]); e == nil {
				if e := get(); e == nil {
					t.Fatal("established flow escaped after classifier disappeared")
				}
				return
			}
			time.Sleep(100 * time.Millisecond)
		}
		t.Fatal("fixture did not signal")
	default:
		t.Fatal("unknown fixture mode")
	}
}
