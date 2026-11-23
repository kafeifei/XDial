import Darwin
import Foundation
import Libbox
import Network

// End-to-end check of the relay socket: the Provider's real client
// (`RelayStreamConnection`) against the real sing-box entry inside Libbox, over
// a real socket file. The unit tests on each side speak to a stand-in for the
// other; this is the only place the two implementations meet outside the
// system extension.
//
// Run with `make test-relay-socket-bridge`.

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func require(
    _ condition: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String
) throws {
    if !condition() {
        throw CheckFailure(description: message())
    }
}

let username = "session-user"
let password = "session-password"

/// SOCKS5 username/password authentication on a relay socket connection.
func authenticate(_ connection: RelayStreamConnection) async throws {
    try await connection.send(Data([0x05, 0x01, 0x02]))
    let method = try await connection.receiveExactly(2)
    try require(method == Data([0x05, 0x02]), "method reply \(Array(method))")
    var request = Data([0x01, UInt8(username.utf8.count)])
    request.append(contentsOf: username.utf8)
    request.append(UInt8(password.utf8.count))
    request.append(contentsOf: password.utf8)
    try await connection.send(request)
    let reply = try await connection.receiveExactly(2)
    try require(reply == Data([0x01, 0x00]), "authentication reply \(Array(reply))")
}

func connect(
    _ connection: RelayStreamConnection,
    port: UInt16
) async throws {
    try await authenticate(connection)
    try await connection.send(
        Data([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, UInt8(port >> 8), UInt8(port & 0xff)])
    )
    let reply = try await connection.receiveExactly(10)
    try require(reply[1] == 0x00, "connect reply \(Array(reply))")
}

/// A loopback TCP origin. `serve` gets each accepted socket on its own thread.
func listenTCP(_ serve: @escaping @Sendable (Int32) -> Void) throws -> UInt16 {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(listener, $0, length) == 0
                && listen(listener, 8) == 0
                && getsockname(listener, $0, &length) == 0
        }
    }
    guard listener >= 0, bound else {
        throw CheckFailure(description: "listen origin: errno \(errno)")
    }
    Thread.detachNewThread {
        while true {
            let accepted = accept(listener, nil, nil)
            guard accepted >= 0 else {
                return
            }
            Thread.detachNewThread {
                serve(accepted)
            }
        }
    }
    return UInt16(bigEndian: address.sin_port)
}

@Sendable func echoUntilEnd(_ descriptor: Int32) {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = read(descriptor, &buffer, buffer.count)
        guard count > 0 else {
            break
        }
        var offset = 0
        while offset < count {
            let written = buffer.withUnsafeBytes {
                write(descriptor, $0.baseAddress! + offset, count - offset)
            }
            guard written > 0 else {
                close(descriptor)
                return
            }
            offset += written
        }
    }
    close(descriptor)
}

func runChecks() async throws {
    var template = Array("/tmp/xdrcXXXXXX".utf8CString)
    guard let created = mkdtemp(&template) else {
        throw CheckFailure(description: "mkdtemp: errno \(errno)")
    }
    let container = URL(fileURLWithPath: String(cString: created), isDirectory: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let relaySocketPath = try RelaySocketDirectory(container: container).makeSocketPath()

    let configuration: [String: Any] = [
        "log": ["disabled": true],
        "inbounds": [[
            "type": "socks",
            "tag": "transparent-proxy-in",
            "xdial_relay_socket": relaySocketPath,
            "xdial_flow_metadata": true,
            "users": [["username": username, "password": password]],
        ]],
        "outbounds": [["type": "direct", "tag": "direct"]],
        "route": ["final": "direct"],
    ]
    let configurationJSON = String(
        decoding: try JSONSerialization.data(withJSONObject: configuration),
        as: UTF8.self
    )
    guard let engine = LibboxNew(nil) else {
        throw CheckFailure(description: "Libbox is unavailable")
    }
    let loopbackIndex = Int(if_nametoindex("lo0"))
    engine.setDefaultInterface("lo0", index: loopbackIndex)
    try engine.setNetworkInterfaces(
        #"[{"name":"lo0","index":\#(loopbackIndex),"type":"other"}]"#
    )
    try engine.startStandalone(configurationJSON)
    var stopped = false
    defer {
        if !stopped {
            try? engine.stop()
        }
    }

    var status = stat()
    try require(
        lstat(relaySocketPath, &status) == 0
            && status.st_mode & S_IFMT == S_IFSOCK
            && status.st_mode & 0o777 == 0o600,
        "relay socket is not an owner-only socket file"
    )
    print("ok  entry listens on an owner-only socket file (\(relaySocketPath.utf8.count) bytes)")

    // TCP: bytes both ways, then a clean end in both directions.
    let echoPort = try listenTCP(echoUntilEnd)
    let clean = RelayStreamConnection(socketPath: relaySocketPath)
    try await clean.start()
    try await connect(clean, port: echoPort)
    let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    async let sent: Void = clean.send(payload)
    var echoed = Data()
    while echoed.count < payload.count {
        guard let bytes = try await clean.receive() else {
            throw CheckFailure(description: "stream finished after \(echoed.count) bytes")
        }
        echoed.append(bytes)
    }
    try await sent
    try require(echoed == payload, "echoed bytes differ")
    try await clean.finishSending()
    let end = try await clean.receive()
    try require(end == nil, "a finished exchange did not end with a FIN frame")
    clean.cancel(with: nil)
    print("ok  TCP relays \(payload.count) bytes each way and ends cleanly")

    // TCP: an upstream reset must reach the Provider as a reset.
    let resetPort = try listenTCP { descriptor in
        var buffer = [UInt8](repeating: 0, count: 4)
        _ = read(descriptor, &buffer, 4)
        var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
        setsockopt(
            descriptor, SOL_SOCKET, SO_LINGER,
            &linger, socklen_t(MemoryLayout<Darwin.linger>.size)
        )
        close(descriptor)
    }
    let reset = RelayStreamConnection(socketPath: relaySocketPath)
    try await reset.start()
    try await connect(reset, port: resetPort)
    try await reset.send(Data("ping".utf8))
    do {
        while try await reset.receive() != nil {}
        throw CheckFailure(description: "an upstream reset was reported as a clean end")
    } catch let error as NWError {
        try require(error == .posix(.ECONNRESET), "unexpected error \(error)")
    }
    reset.cancel(with: CancellationError())
    print("ok  an upstream reset reaches the Provider as a reset")

    // Wrong credentials are still refused on the socket file.
    let intruder = RelayStreamConnection(socketPath: relaySocketPath)
    try await intruder.start()
    try await intruder.send(Data([0x05, 0x01, 0x00]))
    let refused = try await intruder.receiveExactly(2)
    try require(refused == Data([0x05, 0xff]), "unauthenticated greeting got \(Array(refused))")
    intruder.cancel(with: CancellationError())
    print("ok  the entry still requires the session credentials")

    // UDP: datagrams follow the handshake on the control connection.
    let udp = socket(AF_INET, SOCK_DGRAM, 0)
    var udpAddress = sockaddr_in()
    udpAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    udpAddress.sin_family = sa_family_t(AF_INET)
    udpAddress.sin_addr.s_addr = inet_addr("127.0.0.1")
    var udpLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let udpBound = withUnsafeMutablePointer(to: &udpAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(udp, $0, udpLength) == 0 && getsockname(udp, $0, &udpLength) == 0
        }
    }
    try require(udp >= 0 && udpBound, "bind UDP origin: errno \(errno)")
    let udpPort = UInt16(bigEndian: udpAddress.sin_port)
    Thread.detachNewThread {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var peer = sockaddr_storage()
        while true {
            var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(udp, &buffer, buffer.count, 0, $0, &peerLength)
                }
            }
            guard count > 0 else {
                return
            }
            _ = withUnsafePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(udp, buffer, count, 0, $0, peerLength)
                }
            }
        }
    }
    let association = RelayStreamConnection(socketPath: relaySocketPath)
    try await association.start()
    try await authenticate(association)
    try await association.send(Data([0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
    let associated = try await association.receiveExactly(10)
    try require(
        associated == Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
        "UDP ASSOCIATE announced a relay endpoint: \(Array(associated))"
    )
    let header = Data([0, 0, 0, 0x01, 127, 0, 0, 1, UInt8(udpPort >> 8), UInt8(udpPort & 0xff)])
    for text in ["first datagram", "second datagram"] {
        let datagram = header + Data(text.utf8)
        try await association.sendDatagram(datagram)
        let reply = try await association.receiveFrame()
        try require(reply == datagram, "echoed datagram differs for \(text)")
    }
    association.cancel(with: CancellationError())
    close(udp)
    print("ok  UDP datagrams travel on the control connection, no relay port")

    try engine.stop()
    stopped = true
    try require(
        lstat(relaySocketPath, &status) != 0 && errno == ENOENT,
        "stopping the data plane left its relay socket behind"
    )
    print("ok  stopping the data plane removes the socket file")
}

@main
enum RelaySocketCheck {
    static func main() async {
        // A hung connection must fail the check, not the build that runs it.
        let watchdog = DispatchWorkItem {
            print("FAIL relay socket check timed out")
            exit(1)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: watchdog)
        do {
            try await runChecks()
        } catch {
            print("FAIL \(error)")
            exit(1)
        }
        watchdog.cancel()
        print("relay socket check passed")
    }
}
