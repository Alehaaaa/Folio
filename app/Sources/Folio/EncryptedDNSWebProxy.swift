import Foundation
import Network

/// WebKit loads pages in its own system process, which never sees Folio's
/// encrypted DNS setting. This tiny HTTP CONNECT proxy on 127.0.0.1 gives the
/// background source browser a way through it: WebKit asks the proxy for
/// "host:port", the proxy opens that connection inside Folio (where the
/// encrypted resolver applies) and then only relays bytes. TLS still runs end
/// to end between WebKit and the website; the proxy never sees the content.
final class FolioEncryptedDNSWebProxy: @unchecked Sendable {
    static let shared = FolioEncryptedDNSWebProxy()

    private let queue = DispatchQueue(label: "folio.dns.webproxy")
    private var listener: NWListener?
    private var readyPort: NWEndpoint.Port?
    private var waiting: [CheckedContinuation<NWEndpoint.Port?, Never>] = []

    /// Testing aid: how many tunnels have been opened.
    private(set) var tunnelsOpened = 0

    /// The proxy settings for a WebKit data store, starting the proxy on
    /// first use. Empty when it can't start, so WebKit loads directly.
    func proxyConfigurations() async -> [ProxyConfiguration] {
        guard let port = await port() else { return [] }
        return [ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: port))]
    }

    func port() async -> NWEndpoint.Port? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let readyPort { return continuation.resume(returning: readyPort) }
                waiting.append(continuation)
                if listener == nil { startListener() }
            }
        }
    }

    private func finishWaiting(_ port: NWEndpoint.Port?) {
        let pending = waiting
        waiting = []
        pending.forEach { $0.resume(returning: port) }
    }

    private func startListener() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.acceptLocalOnly = true
        guard let listener = try? NWListener(using: parameters) else { return finishWaiting(nil) }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.readyPort = listener.port
                self.finishWaiting(listener.port)
            case .failed, .cancelled:
                self.listener = nil
                self.readyPort = nil
                self.finishWaiting(nil)
            default: break
            }
        }
        listener.start(queue: queue)
    }

    private func accept(_ client: NWConnection) {
        client.start(queue: queue)
        readHead(client, buffer: Data())
    }

    /// Reads the request head ("CONNECT host:port HTTP/1.1 ... \r\n\r\n").
    private func readHead(_ client: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            guard let self else { return client.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard error == nil, buffer.count < 65_536 else { return client.cancel() }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                return done ? client.cancel() : self.readHead(client, buffer: buffer)
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let rest = buffer[end.upperBound...]
            self.open(client, head: head, rest: Data(rest), original: buffer)
        }
    }

    private func open(_ client: NWConnection, head: String, rest: Data, original: Data) {
        let parts = (head.split(separator: "\r\n").first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return reject(client) }
        let method = parts[0].uppercased()
        let host: String, port: UInt16, firstBytes: Data, reply: Data?
        if method == "CONNECT" {
            guard let (h, p) = Self.hostPort(String(parts[1]), defaultPort: 443) else { return reject(client) }
            (host, port, firstBytes) = (h, p, rest)
            reply = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
        } else {
            // Plain http:// sent in absolute form: forward the request as is.
            guard let url = URL(string: String(parts[1])), url.scheme?.lowercased() == "http",
                  let h = url.host else { return reject(client) }
            (host, port, firstBytes) = (h, UInt16(url.port ?? 80), original)
            reply = nil
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return reject(client) }
        // Default parameters use the app's privacy context, so the name is
        // resolved through the encrypted DNS provider.
        let upstream = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        var settled = false
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self, !settled else { return }
            switch state {
            case .ready:
                settled = true
                self.tunnelsOpened += 1
                let tunnel = Tunnel(client, upstream)
                let start = {
                    self.pipe(from: client, to: upstream, tunnel: tunnel)
                    self.pipe(from: upstream, to: client, tunnel: tunnel)
                }
                let sendFirst = {
                    if firstBytes.isEmpty { return start() }
                    upstream.send(content: firstBytes, completion: .contentProcessed { _ in start() })
                }
                if let reply {
                    client.send(content: reply, completion: .contentProcessed { _ in sendFirst() })
                } else {
                    sendFirst()
                }
            case .failed, .waiting:
                settled = true
                upstream.cancel()
                self.reject(client, status: "502 Bad Gateway")
            default: break
            }
        }
        upstream.start(queue: queue)
    }

    private func reject(_ client: NWConnection, status: String = "400 Bad Request") {
        client.send(content: Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                    completion: .contentProcessed { _ in client.cancel() })
    }

    /// Both directions of one tunnel; both connections end once each
    /// direction has finished, or right away on an error.
    private final class Tunnel {
        let a: NWConnection, b: NWConnection
        var finished = 0
        init(_ a: NWConnection, _ b: NWConnection) { (self.a, self.b) = (a, b) }
        func fail() { a.cancel(); b.cancel() }
        func directionDone() { finished += 1; if finished == 2 { fail() } }
    }

    private func pipe(from source: NWConnection, to destination: NWConnection, tunnel: Tunnel) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            let finish = {
                if error != nil { return tunnel.fail() }
                // Half-close: tell the other side this direction is over.
                destination.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                 completion: .contentProcessed { _ in tunnel.directionDone() })
            }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil { return tunnel.fail() }
                    if done || error != nil { finish() } else { self?.pipe(from: source, to: destination, tunnel: tunnel) }
                })
            } else if done || error != nil {
                finish()
            } else {
                self?.pipe(from: source, to: destination, tunnel: tunnel)
            }
        }
    }

    static func hostPort(_ authority: String, defaultPort: UInt16) -> (String, UInt16)? {
        var text = authority
        var port = defaultPort
        if text.hasPrefix("[") { // [IPv6]:port
            guard let close = text.firstIndex(of: "]") else { return nil }
            let after = text[text.index(after: close)...]
            if after.hasPrefix(":") { guard let p = UInt16(after.dropFirst()) else { return nil }; port = p }
            text = String(text[text.index(after: text.startIndex)..<close])
        } else if let colon = text.lastIndex(of: ":") {
            guard let p = UInt16(text[text.index(after: colon)...]) else { return nil }
            port = p
            text = String(text[..<colon])
        }
        return text.isEmpty ? nil : (text, port)
    }
}
