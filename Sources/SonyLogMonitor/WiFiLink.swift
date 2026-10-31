import Darwin
import Foundation
import Network

/// Wi-Fi (PTP/IP) support for Sony's "PC Remote over Wi-Fi Access Point".
///
/// The camera only accepts computers it has paired with, keyed by the 16-byte GUID in
/// the PTP/IP Init Command. libgphoto2 2.5.34 always sends its own fixed GUID, so the
/// app pairs with a GUID of its own and runs libgphoto2 through a local relay that
/// swaps that GUID into the handshake. Everything after the handshake passes through
/// untouched.
enum WiFiLink {
    static let ptpipPort: UInt16 = 15740

    /// This Mac's identity toward the camera. Generated once, then kept.
    static var guid: Data {
        let key = "wifiGUID"
        if let hex = UserDefaults.standard.string(forKey: key), let d = Data(hex: hex), d.count == 16 { return d }
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        UserDefaults.standard.set(Data(bytes).hex, forKey: key)
        return Data(bytes)
    }

    /// PTP/IP Init Command Request: GUID, UTF-16 name, protocol version 1.0.
    static func initCommand(guid: Data) -> Data {
        var payload = guid
        payload.append(("Bon Log Monitor".data(using: .utf16LittleEndian) ?? Data()) + Data([0, 0]))
        payload.append(le32(0x0001_0000))
        return le32(UInt32(8 + payload.count)) + le32(1) + payload
    }

    static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    // MARK: Pairing

    enum PairResult { case paired, timedOut, failed(String) }

    /// Keeps offering our GUID while the camera is in Network › PC Remote Function ›
    /// Pairing; the camera asks the user to confirm, then answers with an Init Ack.
    /// Blocking: call off the main thread.
    static func pair(host: String, timeout: TimeInterval = 120) -> PairResult {
        let end = Date().addingTimeInterval(timeout)
        let request = initCommand(guid: guid)
        while Date() < end {
            if let cmd = try? BlockingSocket(host: host, port: ptpipPort, timeout: 30) {
                try? cmd.send(request)
                if let head = try? cmd.receive(12) {
                    let type = head.le32(at: 4)
                    if type == 2 {
                        // Finish properly: event channel, OpenSession, CloseSession. A
                        // half-open handshake leaves the camera refusing connections
                        // until it's power-cycled.
                        let conn = head.le32(at: 8)
                        _ = try? cmd.receive(Int(head.le32(at: 0)) - 12)
                        if let ev = try? BlockingSocket(host: host, port: ptpipPort, timeout: 5) {
                            try? ev.send(le32(12) + le32(3) + le32(conn))
                            _ = try? ev.receive(8)
                            for (code, tid, params) in [(UInt16(0x1002), UInt32(1), [UInt32(1)]), (0x1003, 2, [])] {
                                var op = le32(1) + withUnsafeBytes(of: code.littleEndian) { Data($0) } + le32(tid)
                                params.forEach { op += le32($0) }
                                try? cmd.send(le32(UInt32(8 + op.count)) + le32(6) + op)
                                if let h = try? cmd.receive(8) { _ = try? cmd.receive(Int(h.le32(at: 0)) - 8) }
                            }
                        }
                        return .paired
                    }
                }
            }
            Thread.sleep(forTimeInterval: 2)
        }
        return .timedOut
    }

    // MARK: Discovery

    /// Asks the network for Sony cameras over SSDP. Returns (name, host) pairs.
    static func discover(wait: TimeInterval = 3) -> [(name: String, host: String)] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(1900).bigEndian
        addr.sin_addr.s_addr = inet_addr("239.255.255.250")
        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\n"
            + "ST: urn:schemas-sony-com:service:DigitalImaging:1\r\n\r\n"
        _ = msg.withCString { p in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, p, strlen(p), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        var found: [String: String] = [:]
        let end = Date().addingTimeInterval(wait)
        var buf = [UInt8](repeating: 0, count: 2048)
        while Date() < end {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            guard n > 0 else { continue }
            let text = String(decoding: buf[0..<n], as: UTF8.self)
            guard text.contains("SonyImagingDevice") || text.contains("DigitalImaging") else { continue }
            let host = String(cString: inet_ntoa(from.sin_addr))
            if found[host] == nil { found[host] = Self.friendlyName(text) ?? "Sony camera" }
        }
        return found.map { ($0.value, $0.key) }.sorted { $0.host < $1.host }
    }

    /// Reads <friendlyName> from the description the SSDP reply points at.
    private static func friendlyName(_ ssdp: String) -> String? {
        guard let line = ssdp.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("location:") }),
              let url = URL(string: line.dropFirst(9).trimmingCharacters(in: .whitespaces)),
              let xml = try? String(contentsOf: url, encoding: .utf8),
              let a = xml.range(of: "<friendlyName>"), let b = xml.range(of: "</friendlyName>", range: a.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[a.upperBound..<b.lowerBound])
    }
}

/// Local TCP relay: libgphoto2 connects to 127.0.0.1:`port`, every connection is piped
/// to the camera, and the Init Command's GUID is replaced with ours.
final class PTPIPRelay {
    let host: String
    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "bonlogmonitor.ptpip.relay")
    private let guid = WiFiLink.guid

    init(host: String) { self.host = host }

    /// Starts listening on a free loopback port. Returns false if it couldn't.
    func start() -> Bool {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: params) else { return false }
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        guard let p = l.port?.rawValue, p != 0 else { l.cancel(); return false }
        listener = l
        port = p
        return true
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ client: NWConnection) {
        let camera = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: WiFiLink.ptpipPort)!, using: Self.tcpNoDelay)
        client.start(queue: queue)
        camera.start(queue: queue)
        pipe(from: client, to: camera, rewriteHandshake: true, other: camera)
        pipe(from: camera, to: client, rewriteHandshake: false, other: client)
    }

    private static var tcpNoDelay: NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: nil, tcp: tcp)
    }

    private func pipe(from src: NWConnection, to dst: NWConnection, rewriteHandshake: Bool, other: NWConnection, pending: Data = Data()) {
        src.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var chunk = pending + (data ?? Data())
            var rewrite = rewriteHandshake
            if rewrite {
                // Hold bytes until the 8-byte header is in; only an Init Command
                // (type 1) needs the GUID too. The event channel's Init Event (type 3)
                // is 12 bytes and waits for a reply, so it must pass straight through.
                let ended = done || error != nil
                let needs = chunk.count >= 8 && chunk.le32(at: 4) == 1 ? 24 : 8
                if chunk.count < needs, !ended {
                    self.pipe(from: src, to: dst, rewriteHandshake: true, other: other, pending: chunk)
                    return
                }
                if chunk.count >= 24, chunk.le32(at: 4) == 1 {
                    chunk.replaceSubrange(chunk.startIndex + 8..<chunk.startIndex + 24, with: self.guid)
                }
                rewrite = false
            }
            if !chunk.isEmpty { dst.send(content: chunk, completion: .contentProcessed { _ in }) }
            if done || error != nil {
                src.cancel()
                other.cancel()
                return
            }
            self.pipe(from: src, to: dst, rewriteHandshake: rewrite, other: other)
        }
    }
}

/// Small blocking TCP client for the pairing handshake.
private final class BlockingSocket {
    private let fd: Int32

    init(host: String, port: UInt16, timeout: TimeInterval) throws {
        fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if r != 0 { close(fd); throw POSIXError(.ECONNREFUSED) }
    }

    deinit { close(fd) }

    func send(_ d: Data) throws {
        let n = d.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, d.count, 0) }
        if n != d.count { throw POSIXError(.EIO) }
    }

    func receive(_ count: Int) throws -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: max(count, 1))
        while out.count < count {
            let n = recv(fd, &buf, count - out.count, 0)
            if n <= 0 { throw POSIXError(.EIO) }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }
}

extension Data {
    init?(hex: String) {
        var d = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            guard let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex), let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            d.append(b)
            i = j
        }
        self = d
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }

    func le32(at offset: Int) -> UInt32 {
        guard count >= offset + 4 else { return 0 }
        return self[startIndex + offset..<startIndex + offset + 4].enumerated()
            .reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }
}
