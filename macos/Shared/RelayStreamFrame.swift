import Foundation

/// Wire format of the relay socket between the Provider and the sing-box entry
/// in the same process.
///
/// Relaying every flow over loopback TCP made the kernel hand each one an
/// ephemeral port, and a long-lived flow kept that port away from whatever
/// program meant to listen on it. The relay socket is a Unix stream socket and
/// takes no port.
///
/// A Unix stream socket cannot say how it ended: a peer that was cut looks the
/// same as one that finished. Both directions are therefore framed, and a
/// direction that finished cleanly says so with a FIN frame. A stream that ends
/// without one was cut, which is what a TCP reset used to report.
///
///     +------+--------+---------+
///     | type | length | payload |
///     |  1   |   3    | length  |   length is big-endian
///     +------+--------+---------+
///
///     0x01 DATA  one or more payload bytes
///     0x02 FIN   no payload; this direction finished and sends nothing more
///
/// A SOCKS UDP association takes no port either. Once UDP ASSOCIATE has been
/// answered, every DATA frame on its control connection is one SOCKS5 UDP
/// datagram, in both directions.
///
/// The sing-box side is `patches/sing-box/0019-relay-transparent-flows-over-unix-socket.patch`.
enum RelayStreamFrame: Equatable {
    case data(Data)
    case finish

    static let headerLength = 4
    /// The largest SOCKS5 UDP datagram is 65507 payload bytes behind a header
    /// of at most 262 bytes.
    static let maximumPayloadLength = 1 << 17
    /// A byte stream is cut into frames of this size at most, so the receiver
    /// never has to hold much of one before it can pass the bytes on.
    static let streamChunkLength = 32 * 1024

    private static let dataType: UInt8 = 0x01
    private static let finishType: UInt8 = 0x02

    static let encodedFinish = Data([finishType, 0x00, 0x00, 0x00])

    /// Encodes `payload` as exactly one DATA frame, which is one datagram.
    static func encodeDatagram(_ payload: Data) -> Data? {
        guard !payload.isEmpty, payload.count <= maximumPayloadLength else {
            return nil
        }
        var frame = Data(capacity: headerLength + payload.count)
        appendHeader(type: dataType, length: payload.count, to: &frame)
        frame.append(payload)
        return frame
    }

    /// Encodes a piece of a byte stream as one or more DATA frames.
    static func encodeStream(_ bytes: Data) -> Data {
        let frameCount = (bytes.count + streamChunkLength - 1) / streamChunkLength
        var encoded = Data(capacity: bytes.count + frameCount * headerLength)
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            let end = min(offset + streamChunkLength, bytes.endIndex)
            appendHeader(type: dataType, length: end - offset, to: &encoded)
            encoded.append(bytes[offset..<end])
            offset = end
        }
        return encoded
    }

    private static func appendHeader(
        type: UInt8,
        length: Int,
        to frame: inout Data
    ) {
        frame.append(type)
        frame.append(UInt8((length >> 16) & 0xff))
        frame.append(UInt8((length >> 8) & 0xff))
        frame.append(UInt8(length & 0xff))
    }

    fileprivate static func parseHeader(
        _ header: Data
    ) throws -> (frame: RelayStreamFrame?, payloadLength: Int) {
        let base = header.startIndex
        let length = Int(header[base + 1]) << 16
            | Int(header[base + 2]) << 8
            | Int(header[base + 3])
        switch header[base] {
        case dataType where length > 0 && length <= maximumPayloadLength:
            return (nil, length)
        case finishType where length == 0:
            return (.finish, 0)
        default:
            throw RelayStreamFrameError.malformed
        }
    }
}

enum RelayStreamFrameError: Error, Equatable {
    /// The stream is not a relay stream, or it went on after its FIN frame.
    case malformed
}

/// Reassembles frames from the pieces a stream socket delivers.
struct RelayStreamFrameDecoder {
    /// Bytes received and not yet handed out start at `consumed`. Dropping
    /// them frame by frame would copy the rest of the buffer every time.
    private var buffer = Data()
    private var consumed = 0
    private(set) var finished = false

    /// Whether bytes have arrived that do not yet make a whole frame. A stream
    /// that ends here was cut inside a frame.
    var hasPartialFrame: Bool {
        consumed < buffer.count
    }

    mutating func append(_ bytes: Data) {
        if consumed == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            consumed = 0
        } else if consumed >= RelayStreamFrame.maximumPayloadLength {
            buffer.removeSubrange(0..<consumed)
            consumed = 0
        }
        buffer.append(bytes)
    }

    /// Returns the next whole frame, or `nil` when more bytes are needed.
    mutating func next() throws -> RelayStreamFrame? {
        let available = buffer.count - consumed
        guard !finished else {
            if available == 0 {
                return nil
            }
            throw RelayStreamFrameError.malformed
        }
        guard available >= RelayStreamFrame.headerLength else {
            return nil
        }
        let headerEnd = consumed + RelayStreamFrame.headerLength
        let parsed = try RelayStreamFrame.parseHeader(
            buffer[consumed..<headerEnd]
        )
        if let frame = parsed.frame {
            consumed = headerEnd
            finished = true
            return frame
        }
        let payloadEnd = headerEnd + parsed.payloadLength
        guard buffer.count >= payloadEnd else {
            return nil
        }
        let payload = buffer.subdata(in: headerEnd..<payloadEnd)
        consumed = payloadEnd
        return .data(payload)
    }
}
