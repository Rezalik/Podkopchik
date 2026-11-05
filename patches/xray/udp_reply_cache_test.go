// SPDX-License-Identifier: MPL-2.0

package dokodemo

import (
	"errors"
	"net"
	"sync"
	"testing"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
)

type cacheTestConn struct {
	mu     sync.Mutex
	closed int
	broken bool
}

func (c *cacheTestConn) Close() error                           { c.mu.Lock(); defer c.mu.Unlock(); c.closed++; return nil }
func (c *cacheTestConn) ReadFrom([]byte) (int, net.Addr, error) { return 0, nil, net.ErrClosed }
func (c *cacheTestConn) LocalAddr() net.Addr                    { return &net.UDPAddr{} }
func (c *cacheTestConn) SetDeadline(time.Time) error            { return nil }
func (c *cacheTestConn) SetReadDeadline(time.Time) error        { return nil }
func (c *cacheTestConn) SetWriteDeadline(time.Time) error       { return nil }
func (c *cacheTestConn) WriteTo(p []byte, a net.Addr) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed != 0 || c.broken {
		return 0, net.ErrClosed
	}
	return len(p), nil
}

func cacheTestPeer(i int) xnet.Destination {
	return xnet.UDPDestination(xnet.IPAddress(net.IPv4(127, 64, byte(i/250), byte(i%250+1)).To4()), 31000)
}

func TestUDPReplyCacheBudgetReopenAndDefault(t *testing.T) {
	var all []*cacheTestConn
	factory := func(xnet.Destination) (net.PacketConn, error) {
		c := &cacheTestConn{}
		all = append(all, c)
		return c, nil
	}
	first, _ := factory(cacheTestPeer(0))
	c := newUDPReplyCache(cacheTestPeer(0), first, factory, 4, time.Minute, time.Minute)
	defer c.Close()
	for i := 1; i < 10000; i++ {
		if _, err := c.writeTo(cacheTestPeer(i), []byte("payload"), &net.UDPAddr{}); err != nil {
			t.Fatal(err)
		}
		c.mu.Lock()
		n := len(c.entries)
		c.mu.Unlock()
		if n > 4 {
			t.Fatalf("unbounded reply cache: %d", n)
		}
	}
	// Revisit an evicted endpoint, including the original/default endpoint.
	for _, i := range []int{1, 0, 9999} {
		if _, err := c.writeTo(cacheTestPeer(i), []byte("reply"), &net.UDPAddr{}); err != nil {
			t.Fatal(err)
		}
	}
	if err := c.Close(); err != nil {
		t.Fatal(err)
	}
	if err := c.Close(); err != nil {
		t.Fatal(err)
	}
	for _, conn := range all {
		if conn.closed != 1 {
			t.Fatalf("connection closed %d times", conn.closed)
		}
	}
	if _, err := c.writeTo(cacheTestPeer(0), nil, &net.UDPAddr{}); err == nil {
		t.Fatal("write after close succeeded")
	}
}

func TestUDPReplyCacheIdleSweepWhileOtherPeerActive(t *testing.T) {
	initial := &cacheTestConn{}
	c := newUDPReplyCache(cacheTestPeer(0), initial, func(xnet.Destination) (net.PacketConn, error) { return &cacheTestConn{}, nil }, 4, 40*time.Millisecond, 5*time.Millisecond)
	defer c.Close()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := c.writeTo(cacheTestPeer(1), []byte("active"), &net.UDPAddr{}); err != nil {
			t.Fatal(err)
		}
		initial.mu.Lock()
		closed := initial.closed
		initial.mu.Unlock()
		if closed == 1 {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("idle peer retained by activity on another peer")
}

func TestUDPReplyCacheTimerClosesCompletelyIdleCache(t *testing.T) {
	initial := &cacheTestConn{}
	c := newUDPReplyCache(cacheTestPeer(0), initial, func(xnet.Destination) (net.PacketConn, error) { return &cacheTestConn{}, nil }, 4, 10*time.Millisecond, 2*time.Millisecond)
	defer c.Close()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		c.mu.Lock()
		n, timer := len(c.entries), c.timer
		c.mu.Unlock()
		if n == 0 && timer == nil {
			if _, err := c.writeTo(cacheTestPeer(0), []byte("reopen"), &net.UDPAddr{}); err != nil {
				t.Fatal(err)
			}
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("idle cleanup timer did not retire the cache")
}

func TestUDPReplyCacheCreationAndWriteErrors(t *testing.T) {
	initial := &cacheTestConn{broken: true}
	c := newUDPReplyCache(cacheTestPeer(0), initial, func(xnet.Destination) (net.PacketConn, error) { return nil, errors.New("fixture") }, 4, time.Minute, time.Minute)
	defer c.Close()
	if _, err := c.writeTo(cacheTestPeer(0), nil, &net.UDPAddr{}); err == nil {
		t.Fatal("broken write succeeded")
	}
	if _, err := c.writeTo(cacheTestPeer(1), nil, &net.UDPAddr{}); err == nil {
		t.Fatal("broken factory succeeded")
	}
	if len(c.entries) != 0 || initial.closed != 1 {
		t.Fatal("failed socket retained")
	}
}

func TestUDPReplyCacheConcurrentWriteSweepClose(t *testing.T) {
	c := newUDPReplyCache(cacheTestPeer(0), &cacheTestConn{}, func(xnet.Destination) (net.PacketConn, error) { return &cacheTestConn{}, nil }, 4, time.Millisecond, time.Millisecond)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			for n := 0; n < 300; n++ {
				_, _ = c.writeTo(cacheTestPeer(i*300+n), []byte("race"), &net.UDPAddr{})
			}
		}(i)
	}
	wg.Add(1)
	go func() { defer wg.Done(); time.Sleep(time.Millisecond); _ = c.Close() }()
	wg.Wait()
	_ = c.Close()
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.closed || len(c.entries) != 0 || c.timer != nil {
		t.Fatal("close left resources")
	}
}

type blockingReplyConn struct {
	cacheTestConn
	started chan struct{}
	stop    chan struct{}
	once    sync.Once
}

func (c *blockingReplyConn) WriteTo([]byte, net.Addr) (int, error) {
	close(c.started)
	<-c.stop
	return 0, net.ErrClosed
}

func (c *blockingReplyConn) Close() error {
	c.once.Do(func() { close(c.stop) })
	return nil
}

func TestUDPReplyCacheCloseInterruptsBlockedWrite(t *testing.T) {
	conn := &blockingReplyConn{started: make(chan struct{}), stop: make(chan struct{})}
	c := newUDPReplyCache(cacheTestPeer(0), conn, func(xnet.Destination) (net.PacketConn, error) { return &cacheTestConn{}, nil }, 4, time.Minute, time.Minute)
	defer c.Close()
	written := make(chan struct{})
	go func() { _, _ = c.writeTo(cacheTestPeer(0), []byte("blocked"), &net.UDPAddr{}); close(written) }()
	<-conn.started
	closed := make(chan struct{})
	go func() { _ = c.Close(); close(closed) }()
	select {
	case <-closed:
	case <-time.After(time.Second):
		t.Fatal("close blocked behind WriteTo")
	}
	select {
	case <-written:
	case <-time.After(time.Second):
		t.Fatal("socket close did not interrupt write")
	}
}
