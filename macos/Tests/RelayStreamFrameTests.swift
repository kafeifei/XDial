import XCTest

final class RelayStreamFrameTests: XCTestCase {
    /// The sing-box entry is written in Go against the same bytes. These pin
    /// the wire format so neither side can drift alone.
    func testWireFormatIsPinned() {
        XCTAssertEqual(
            RelayStreamFrame.encodeDatagram(Data([0xAA, 0xBB])),
            Data([0x01, 0x00, 0x00, 0x02, 0xAA, 0xBB])
        )
        XCTAssertEqual(
            RelayStreamFrame.encodedFinish,
            Data([0x02, 0x00, 0x00, 0x00])
        )
        XCTAssertEqual(RelayStreamFrame.headerLength, 4)
        XCTAssertEqual(RelayStreamFrame.maximumPayloadLength, 131_072)
        XCTAssertEqual(RelayStreamFrame.streamChunkLength, 32_768)
    }

    func testStreamIsCutIntoBoundedFrames() throws {
        let bytes = Data((0..<(RelayStreamFrame.streamChunkLength * 2 + 5)).map {
            UInt8(truncatingIfNeeded: $0)
        })
        var decoder = RelayStreamFrameDecoder()
        decoder.append(RelayStreamFrame.encodeStream(bytes))
        var lengths: [Int] = []
        var reassembled = Data()
        while case let .data(payload)? = try decoder.next() {
            lengths.append(payload.count)
            reassembled.append(payload)
        }
        XCTAssertEqual(lengths, [32_768, 32_768, 5])
        XCTAssertEqual(reassembled, bytes)
        XCTAssertFalse(decoder.hasPartialFrame)
        XCTAssertEqual(RelayStreamFrame.encodeStream(Data()), Data())
    }

    func testStreamEncodingHonorsSliceIndices() throws {
        let backing = Data([0x00, 0x01, 0x02, 0x03, 0x04])
        var decoder = RelayStreamFrameDecoder()
        decoder.append(RelayStreamFrame.encodeStream(backing.dropFirst(2)))
        XCTAssertEqual(try decoder.next(), .data(Data([0x02, 0x03, 0x04])))
    }

    func testDatagramIsExactlyOneFrameOrRefused() throws {
        let largest = Data(repeating: 0x5A, count: RelayStreamFrame.maximumPayloadLength)
        var decoder = RelayStreamFrameDecoder()
        decoder.append(try XCTUnwrap(RelayStreamFrame.encodeDatagram(largest)))
        XCTAssertEqual(try decoder.next(), .data(largest))
        XCTAssertNil(try decoder.next())

        XCTAssertNil(RelayStreamFrame.encodeDatagram(Data()))
        XCTAssertNil(
            RelayStreamFrame.encodeDatagram(
                Data(count: RelayStreamFrame.maximumPayloadLength + 1)
            )
        )
    }

    /// A stream socket delivers bytes in whatever pieces it likes.
    func testFramesSurviveEveryPossibleSplit() throws {
        var wire = RelayStreamFrame.encodeDatagram(Data("first".utf8))!
        wire.append(RelayStreamFrame.encodeDatagram(Data("second".utf8))!)
        wire.append(RelayStreamFrame.encodedFinish)
        for split in 0...wire.count {
            var decoder = RelayStreamFrameDecoder()
            var frames: [RelayStreamFrame] = []
            for piece in [wire.prefix(split), wire.dropFirst(split)] {
                decoder.append(Data(piece))
                while let frame = try decoder.next() {
                    frames.append(frame)
                }
            }
            XCTAssertEqual(
                frames,
                [.data(Data("first".utf8)), .data(Data("second".utf8)), .finish],
                "split at \(split)"
            )
            XCTAssertTrue(decoder.finished)
        }
    }

    func testManySmallFramesInOneReadAreAllDelivered() throws {
        var wire = Data()
        for index in 0..<5_000 {
            wire.append(RelayStreamFrame.encodeDatagram(Data([UInt8(index % 251)]))!)
        }
        var decoder = RelayStreamFrameDecoder()
        var count = 0
        // Fed in pieces so the decoder has to drop consumed bytes on the way.
        for start in stride(from: 0, to: wire.count, by: 60_000) {
            decoder.append(wire.subdata(in: start..<min(start + 60_000, wire.count)))
            while case let .data(payload)? = try decoder.next() {
                XCTAssertEqual(payload, Data([UInt8(count % 251)]))
                count += 1
            }
        }
        XCTAssertEqual(count, 5_000)
    }

    func testPartialFrameIsVisibleSoACutInsideItIsNotACleanEnd() throws {
        var decoder = RelayStreamFrameDecoder()
        XCTAssertFalse(decoder.hasPartialFrame)
        decoder.append(Data([0x01, 0x00]))
        XCTAssertNil(try decoder.next())
        XCTAssertTrue(decoder.hasPartialFrame)
        decoder.append(Data([0x00, 0x03, 0x61]))
        XCTAssertNil(try decoder.next())
        XCTAssertTrue(decoder.hasPartialFrame)
        XCTAssertFalse(decoder.finished)
    }

    func testMalformedStreamsAreRejected() {
        let cases: [(String, Data)] = [
            ("plain SOCKS greeting", Data([0x05, 0x01, 0x00, 0x00])),
            ("unknown frame type", Data([0x00, 0x00, 0x00, 0x00])),
            ("empty DATA frame", Data([0x01, 0x00, 0x00, 0x00])),
            ("oversized DATA frame", Data([0x01, 0x02, 0x00, 0x01])),
            ("FIN with a payload", Data([0x02, 0x00, 0x00, 0x01, 0x00])),
            ("bytes after FIN", Data([0x02, 0x00, 0x00, 0x00, 0x01])),
        ]
        for (name, wire) in cases {
            var decoder = RelayStreamFrameDecoder()
            decoder.append(wire)
            XCTAssertThrowsError(
                try { while try decoder.next() != nil {} }(),
                name
            ) { error in
                XCTAssertEqual(error as? RelayStreamFrameError, .malformed, name)
            }
        }
    }
}
