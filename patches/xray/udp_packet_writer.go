// SPDX-License-Identifier: MPL-2.0

package dokodemo

import (
	"context"

	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/net"
)

func NewPacketWriter(conn net.PacketConn, d *net.Destination, mark int, back *net.UDPAddr) buf.Writer {
	w := &PacketWriter{destination: *d, back: back}
	w.cache = newUDPReplyCache(*d, conn, func(peer net.Destination) (net.PacketConn, error) {
		return FakeUDP(&net.UDPAddr{IP: peer.Address.IP(), Port: int(peer.Port)}, mark)
	}, udpReplyCacheLimit, udpReplyIdle, udpReplySweep)
	return w
}

type PacketWriter struct {
	destination net.Destination
	back        *net.UDPAddr
	cache       *udpReplyCache
}

func (w *PacketWriter) WriteMultiBuffer(mb buf.MultiBuffer) error {
	for {
		mb2, b := buf.SplitFirst(mb)
		mb = mb2
		if b == nil {
			break
		}
		peer := w.destination
		explicit := b.UDP != nil && b.UDP.Address.Family().IsIP()
		if explicit {
			peer = *b.UDP
		}
		_, err := w.cache.writeTo(peer, b.Bytes(), w.back)
		b.Release()
		if err != nil {
			if explicit {
				errors.LogInfo(context.Background(), err.Error())
				continue
			}
			buf.ReleaseMulti(mb)
			return err
		}
	}
	return nil
}

func (w *PacketWriter) Close() error {
	return w.cache.Close()
}
