import Foundation
import Network

/// Latest rendered monitor frame (overlays included) as JPEG, fanned out to every
/// phone watching /stream. A slow phone drops frames instead of building a backlog.
final class PhoneFrameHub {
    private let lock = NSLock()
    private var clients: [ObjectIdentifier: (conn: NWConnection, busy: Bool)] = [:]

    var hasClients: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !clients.isEmpty
    }

    func add(_ conn: NWConnection) {
        lock.lock()
        clients[ObjectIdentifier(conn)] = (conn, false)
        lock.unlock()
    }

    func remove(_ conn: NWConnection) {
        lock.lock()
        clients[ObjectIdentifier(conn)] = nil
        lock.unlock()
    }

    func publish(jpeg: Data) {
        var part = Data("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
        part.append(jpeg)
        part.append(Data("\r\n".utf8))
        lock.lock()
        let ready = clients.values.filter { !$0.busy }.map(\.conn)
        for c in ready { clients[ObjectIdentifier(c)]?.busy = true }
        lock.unlock()
        for c in ready {
            c.send(content: part, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil {
                    self.remove(c)
                    c.cancel()
                    return
                }
                self.lock.lock()
                self.clients[ObjectIdentifier(c)]?.busy = false
                self.lock.unlock()
            })
        }
    }
}

/// Tiny HTTP server for the phone view: the page, an MJPEG stream, a JSON state feed
/// and GET commands. Home-network only; there's no auth, so don't port-forward it.
final class PhoneServer {
    let hub = PhoneFrameHub()
    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "sonylogmonitor.phone")
    /// Answers /state (called on the main thread).
    var state: () -> [String: Any] = { [:] }
    /// Runs a /cmd query (called on the main thread).
    var command: ([String: String]) -> Void = { _ in }
    /// Answers /audio: [[level, peak], ...] in dBFS per channel (main thread).
    var audio: () -> [[Double]] = { [] }

    func start(preferredPort: UInt16 = 8080) {
        for p in preferredPort..<(preferredPort + 10) {
            guard let nwPort = NWEndpoint.Port(rawValue: p), let l = try? NWListener(using: .tcp, on: nwPort) else { continue }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: queue)
            listener = l
            port = p
            return
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let line = request.split(separator: "\r\n").first else { conn.cancel(); return }
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { conn.cancel(); return }
            self.route(String(parts[1]), conn)
        }
    }

    private func route(_ target: String, _ conn: NWConnection) {
        let comps = URLComponents(string: target)
        let path = comps?.path ?? target
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }

        switch path {
        case "/":
            respond(conn, type: "text/html; charset=utf-8", body: Data(PhonePage.html.utf8))
        case "/stream":
            let head = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\n"
                + "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
                if error == nil { self?.hub.add(conn) } else { conn.cancel() }
            })
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.hub.remove(conn)
                default: break
                }
            }
        case "/state":
            let s = DispatchQueue.main.sync { state() }
            let body = (try? JSONSerialization.data(withJSONObject: s)) ?? Data("{}".utf8)
            respond(conn, type: "application/json", body: body)
        case "/audio":
            let a = DispatchQueue.main.sync { audio() }
            let body = (try? JSONSerialization.data(withJSONObject: a)) ?? Data("[]".utf8)
            respond(conn, type: "application/json", body: body)
        case "/cmd":
            DispatchQueue.main.async { self.command(query) }
            respond(conn, type: "application/json", body: Data("{\"ok\":true}".utf8))
        default:
            respond(conn, status: "404 Not Found", type: "text/plain", body: Data("not found".utf8))
        }
    }

    private func respond(_ conn: NWConnection, status: String = "200 OK", type: String, body: Data) {
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// This Mac's IPv4 address on Wi-Fi/Ethernet, for the URL the phone opens.
    static func lanAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: host)
            if name == "en0" { return ip }
            fallback = fallback ?? ip
        }
        return fallback
    }
}
