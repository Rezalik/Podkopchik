// SPDX-License-Identifier: MPL-2.0

package dokodemo

import (
	"container/list"
	"io"
	"net"
	"sync"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
)

const (
	udpReplyCacheLimit = 128
	udpReplyIdle       = 120 * time.Second
	udpReplySweep      = 30 * time.Second
)

type udpReplyEntry struct {
	destination xnet.Destination
	conn        net.PacketConn
	used        time.Time
	writes      int
	closed      bool
}

// Only transparent response sockets are cached here. The outbound full-cone
// receive socket and the UDP association's routing choice remain untouched.
type udpReplyCache struct {
	mu      sync.Mutex
	entries map[xnet.Destination]*list.Element
	lru     *list.List
	factory func(xnet.Destination) (net.PacketConn, error)
	limit   int
	idle    time.Duration
	period  time.Duration
	timer   *time.Timer
	closed  bool
}

func newUDPReplyCache(d xnet.Destination, conn net.PacketConn, factory func(xnet.Destination) (net.PacketConn, error), limit int, idle, period time.Duration) *udpReplyCache {
	c := &udpReplyCache{
		entries: make(map[xnet.Destination]*list.Element), lru: list.New(),
		factory: factory, limit: limit, idle: idle, period: period,
	}
	c.entries[d] = c.lru.PushFront(&udpReplyEntry{destination: d, conn: conn, used: time.Now()})
	c.mu.Lock()
	c.armLocked()
	c.mu.Unlock()
	return c
}

func (c *udpReplyCache) armLocked() {
	c.timer = time.AfterFunc(c.period, c.sweep)
}

func (c *udpReplyCache) removeLocked(e *list.Element) error {
	entry := e.Value.(*udpReplyEntry)
	entry.closed = true
	delete(c.entries, entry.destination)
	c.lru.Remove(e)
	return entry.conn.Close()
}

func (c *udpReplyCache) expireLocked(now time.Time) {
	for e := c.lru.Back(); e != nil; {
		previous := e.Prev()
		entry := e.Value.(*udpReplyEntry)
		if now.Sub(entry.used) < c.idle {
			break
		}
		if entry.writes == 0 {
			_ = c.removeLocked(e)
		}
		e = previous
	}
}

func (c *udpReplyCache) sweep() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return
	}
	c.expireLocked(time.Now())
	c.timer = nil
	if len(c.entries) != 0 {
		c.armLocked()
	}
}

func (c *udpReplyCache) writeTo(d xnet.Destination, payload []byte, back net.Addr) (int, error) {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return 0, io.ErrClosedPipe
	}
	now := time.Now()
	c.expireLocked(now)
	e := c.entries[d]
	if e == nil {
		// Close before allocating: even a churn burst cannot exceed the budget.
		if len(c.entries) >= c.limit {
			victim := c.lru.Back()
			for victim != nil && victim.Value.(*udpReplyEntry).writes != 0 {
				victim = victim.Prev()
			}
			if victim == nil {
				c.mu.Unlock()
				return 0, io.ErrShortBuffer
			}
			_ = c.removeLocked(victim)
		}
		conn, err := c.factory(d)
		if err != nil {
			c.mu.Unlock()
			return 0, err
		}
		e = c.lru.PushFront(&udpReplyEntry{destination: d, conn: conn, used: now})
		c.entries[d] = e
	}
	entry := e.Value.(*udpReplyEntry)
	entry.writes++
	entry.used = now
	c.lru.MoveToFront(e)
	if c.timer == nil {
		c.armLocked()
	}
	c.mu.Unlock()
	// Close must be able to close the socket and interrupt a blocked write.
	n, err := entry.conn.WriteTo(payload, back)
	c.mu.Lock()
	entry.writes--
	if !entry.closed {
		if err != nil {
			_ = c.removeLocked(e)
		} else {
			entry.used = time.Now()
			c.lru.MoveToFront(e)
		}
	}
	c.mu.Unlock()
	return n, err
}

func (c *udpReplyCache) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return nil
	}
	c.closed = true
	if c.timer != nil {
		c.timer.Stop()
		c.timer = nil
	}
	var first error
	for e := c.lru.Back(); e != nil; e = c.lru.Back() {
		if err := c.removeLocked(e); first == nil {
			first = err
		}
	}
	return first
}
