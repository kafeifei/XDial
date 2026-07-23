package vpn

import (
	"sync"

	"sslcon/proto"
)

const BufferSize = 2048

type payloadBufferPool interface {
	Get() interface{}
	Put(interface{})
}

// pool 实际数据缓冲区，缓冲区的容量由 golang 自动控制，PayloadIn 等通道只是个内存地址列表
var pool payloadBufferPool = &sync.Pool{
	New: func() interface{} {
		b := make([]byte, BufferSize)
		pl := proto.Payload{
			Type: 0x00,
			Data: b,
		}
		return &pl
	},
}

func getPayloadBuffer() *proto.Payload {
	pl := pool.Get().(*proto.Payload)
	return pl
}

func putPayloadBuffer(pl *proto.Payload) {
	// DPD-REQ、KEEPALIVE 等数据
	if cap(pl.Data) != BufferSize {
		// base.Debug("payload is:", pl.Data)
		return
	}

	pl.Type = 0x00
	pl.Data = pl.Data[:BufferSize]
	pool.Put(pl)
}

// ReleasePayloadBuffer 归还由 sslcon 数据通道交给外部消费者的 payload。
//
// NoTUN 模式下 PayloadIn 不再由本包的 payloadInToTun 消费，因此桥接层必须在
// 数据复制完成后显式调用本函数。nil 和扩容过的控制包都可安全传入；后者沿用
// putPayloadBuffer 的容量检查，交给 GC 而不污染固定大小的池。
func ReleasePayloadBuffer(pl *proto.Payload) {
	if pl == nil {
		return
	}
	putPayloadBuffer(pl)
}
