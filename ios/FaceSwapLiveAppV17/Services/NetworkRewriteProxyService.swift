import Foundation
import Network
import WebKit

/// Lifecycle status of the experimental Network Rewrite proxy.
nonisolated enum NetworkRewriteStatus: Equatable, Sendable {
    case idle
    case starting
    case running(port: UInt16)
    case unavailable(String)
}

/// UI-facing controller for the experimental **Network Rewrite** injection
/// method. It owns a local on-device proxy (`NetworkRewriteProxyEngine`) and
/// exposes the `ProxyConfiguration` the browser routes through.
///
/// Honest scope: a true HTTPS man-in-the-middle (rewriting encrypted page
/// bodies) requires terminating TLS with a system-trusted certificate, which
/// Apple's Network framework cannot do on an already-established CONNECT
/// tunnel and which can't be verified inside the preview. So this proxy
/// rewrites **plain-HTTP** pages (stripping Content-Security-Policy and
/// integrity locks) and **transparently tunnels HTTPS** so browsing is never
/// broken — HTTPS sites keep relying on the universal camera swap. Everything
/// fails safe: if the proxy can't start, the mode reports unavailable and the
/// page falls back to the proven Canvas Pipeline feed.
@MainActor
@Observable
final class NetworkRewriteProxyService {
    static let shared = NetworkRewriteProxyService()

    private(set) var status: NetworkRewriteStatus = .idle
    private(set) var lastMessage: String = ""

    private let engine = NetworkRewriteProxyEngine()
    private var startWaiters: [CheckedContinuation<Bool, Never>] = []

    private init() {
        engine.onStatus = { [weak self] running, port, message in
            Task { @MainActor in
                guard let self else { return }
                self.lastMessage = message
                if running, port > 0 {
                    self.status = .running(port: port)
                } else if !running {
                    switch self.status {
                    case .starting:
                        self.status = .unavailable(message)
                    case .running:
                        self.status = .idle
                    default:
                        break
                    }
                }
                let waiters = self.startWaiters
                self.startWaiters.removeAll()
                for waiter in waiters { waiter.resume(returning: running && port > 0) }
            }
        }
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    var port: UInt16 {
        if case .running(let p) = status { return p }
        return 0
    }

    var statusText: String {
        switch status {
        case .idle:
            return "Proxy stopped."
        case .starting:
            return "Starting local proxy…"
        case .running(let p):
            return "Running on 127.0.0.1:\(p). Reload the page to route it through the proxy."
        case .unavailable(let m):
            return "Unavailable — \(m). Falling back to the standard camera feed."
        }
    }

    /// The proxy configuration the browser's data store should adopt while the
    /// Network Rewrite method is active. Empty unless the proxy is running.
    var activeProxyConfigurations: [ProxyConfiguration] {
        guard case .running(let p) = status, let nwPort = NWEndpoint.Port(rawValue: p) else { return [] }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
        return [ProxyConfiguration(httpCONNECTProxy: endpoint)]
    }

    /// Starts the proxy (idempotent). Returns whether it is running and ready.
    @discardableResult
    func start() async -> Bool {
        switch status {
        case .running:
            return true
        case .starting:
            // A start is already in flight. Join that attempt instead of calling
            // `engine.start()` again; otherwise a second waiter can be added after
            // the listener exists but before it has a port, leaving that waiter
            // with no status callback to resume it.
            return await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        case .idle, .unavailable:
            status = .starting
            return await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
                engine.start()
            }
        }
    }

    /// Stops the proxy and clears state.
    func shutdown() {
        engine.stop()
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: false) }
        switch status {
        case .running, .starting:
            status = .idle
        default:
            break
        }
    }
}

/// The off-main-actor proxy engine. All network state is confined to a single
/// serial queue; status is reported back through `onStatus` (the caller hops to
/// the main actor). Marked `@unchecked Sendable` because every mutable field is
/// only ever touched on `queue`.
nonisolated final class NetworkRewriteProxyEngine: @unchecked Sendable {
    /// (running, port, message)
    var onStatus: (@Sendable (Bool, UInt16, String) -> Void)?

    private let queue = DispatchQueue(label: "app.rork.faceswap.netrewrite.proxy")
    private var listener: NWListener?
    private let session: URLSession

    /// Hop-by-hop request headers that must not be forwarded upstream.
    private static let stripRequestHeaders: Set<String> = [
        "connection", "proxy-connection", "keep-alive", "transfer-encoding",
        "te", "trailer", "upgrade", "host", "content-length",
        "accept-encoding", "proxy-authorization", "proxy-authenticate"
    ]

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 25
        config.httpShouldSetCookies = true
        session = URLSession(configuration: config)
    }

    func start() {
        queue.async { [self] in startLocked() }
    }

    func stop() {
        queue.async { [self] in stopLocked() }
    }

    // MARK: - Lifecycle (queue-confined)

    private func startLocked() {
        guard listener == nil else {
            if let p = listener?.port?.rawValue, p > 0 {
                onStatus?(true, p, "Local rewrite proxy already running on 127.0.0.1:\(p)")
            }
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let newListener: NWListener
        do {
            newListener = try NWListener(using: params)
        } catch {
            onStatus?(false, 0, "could not create local proxy (\(error.localizedDescription))")
            return
        }
        newListener.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                let port = newListener.port?.rawValue ?? 0
                if port > 0 {
                    onStatus?(true, port, "Local rewrite proxy running on 127.0.0.1:\(port)")
                } else {
                    onStatus?(false, 0, "proxy started without a port")
                }
            case .failed(let error):
                onStatus?(false, 0, "proxy failed (\(error.localizedDescription))")
                stopLocked()
            case .cancelled:
                onStatus?(false, 0, "proxy stopped")
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [self] connection in
            handleConnection(connection)
        }
        listener = newListener
        newListener.start(queue: queue)
    }

    private func stopLocked() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequestHead(connection, buffer: Data())
    }

    private func readRequestHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            var accumulated = buffer
            if let data, !data.isEmpty { accumulated.append(data) }
            if let terminator = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let head = accumulated.subdata(in: accumulated.startIndex..<terminator.upperBound)
                let rest = accumulated.subdata(in: terminator.upperBound..<accumulated.endIndex)
                routeRequest(connection, head: head, rest: rest)
                return
            }
            if isComplete || error != nil || accumulated.count > 262_144 {
                connection.cancel()
                return
            }
            readRequestHead(connection, buffer: accumulated)
        }
    }

    private func routeRequest(_ connection: NWConnection, head: Data, rest: Data) {
        guard let headString = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else {
            connection.cancel()
            return
        }
        let lines = headString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { connection.cancel(); return }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { connection.cancel(); return }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        if method == "CONNECT" {
            startTunnel(client: connection, authority: target, leftover: rest)
        } else {
            handleHTTP(client: connection, method: method, target: target, headerLines: Array(lines.dropFirst()), rest: rest)
        }
    }

    // MARK: - HTTPS transparent tunnel

    private func startTunnel(client: NWConnection, authority: String, leftover: Data) {
        let pieces = authority.split(separator: ":")
        let host = String(pieces.first ?? "")
        let portValue = UInt16(pieces.count > 1 ? String(pieces[1]) : "443") ?? 443
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: portValue) else {
            client.cancel()
            return
        }
        let server = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        server.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                let established = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
                client.send(content: established, completion: .contentProcessed { [self] _ in
                    if !leftover.isEmpty {
                        server.send(content: leftover, completion: .contentProcessed { _ in })
                    }
                    relay(from: client, to: server)
                    relay(from: server, to: client)
                })
            case .failed, .cancelled:
                client.cancel()
            default:
                break
            }
        }
        server.start(queue: queue)
    }

    private func relay(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                source.cancel()
                return
            }
            relay(from: source, to: destination)
        }
    }

    // MARK: - Plain-HTTP rewrite

    private func handleHTTP(client: NWConnection, method: String, target: String, headerLines: [String], rest: Data) {
        guard let url = URL(string: target), url.scheme?.lowercased() == "http", url.host != nil else {
            sendError(client, status: 502)
            return
        }
        var headers: [(String, String)] = []
        var contentLength = 0
        for line in headerLines {
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if name.lowercased() == "content-length" { contentLength = Int(value) ?? 0 }
            headers.append((name, value))
        }
        let frozenHeaders = headers
        readBody(client, have: rest, need: contentLength) { [self, frozenHeaders] body in
            forwardHTTP(client: client, method: method, url: url, headers: frozenHeaders, body: body)
        }
    }

    private func readBody(_ connection: NWConnection, have: Data, need: Int, completion: @escaping @Sendable (Data) -> Void) {
        if have.count >= need {
            completion(Data(have.prefix(max(need, 0))))
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            var accumulated = have
            if let data, !data.isEmpty { accumulated.append(data) }
            if accumulated.count >= need || isComplete || error != nil {
                completion(Data(accumulated.prefix(max(need, 0))))
                return
            }
            readBody(connection, have: accumulated, need: need, completion: completion)
        }
    }

    private func forwardHTTP(client: NWConnection, method: String, url: URL, headers: [(String, String)], body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers where !Self.stripRequestHeaders.contains(name.lowercased()) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if !body.isEmpty { request.httpBody = body }
        let task = session.dataTask(with: request) { [self] data, response, _ in
            guard let http = response as? HTTPURLResponse else {
                sendError(client, status: 502)
                return
            }
            let bytes = NetworkRewriteResponseBuilder.build(response: http, body: data ?? Data())
            client.send(content: bytes, completion: .contentProcessed { _ in client.cancel() })
        }
        task.resume()
    }

    private func sendError(_ connection: NWConnection, status: Int) {
        let body = "Proxy error \(status)"
        let response = "HTTP/1.1 \(status) Proxy Error\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Builds the raw HTTP/1.1 response bytes returned to the browser, rewriting
/// readable HTML (stripping security policies + integrity locks) so injected
/// media is never rejected.
nonisolated enum NetworkRewriteResponseBuilder {
    /// Response headers we drop or replace (CSP, framing, encoding, hop-by-hop,
    /// and Set-Cookie — which is rebuilt separately below, one line per cookie).
    private static let dropResponseHeaders: Set<String> = [
        "content-length", "content-encoding", "transfer-encoding", "connection",
        "keep-alive", "content-security-policy", "content-security-policy-report-only",
        "x-webkit-csp", "strict-transport-security", "x-frame-options", "set-cookie"
    ]

    static func build(response: HTTPURLResponse, body: Data) -> Data {
        var bodyData = body
        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/html"), bodyData.count < 6_000_000 {
            // Real plain-HTTP pages aren't always strict UTF-8; a legacy page
            // declaring Latin-1 (or with no charset at all but non-UTF8 bytes)
            // would otherwise silently skip the rewrite below. isoLatin1 never
            // fails to decode, so it's a safe fallback — but the body must be
            // re-encoded with the SAME encoding that decoded it, never mixed,
            // or non-ASCII bytes would get corrupted.
            if var html = String(data: bodyData, encoding: .utf8) {
                html = stripIntegrity(html)
                html = injectMarker(html)
                if let reEncoded = html.data(using: .utf8) { bodyData = reEncoded }
            } else if var html = String(data: bodyData, encoding: .isoLatin1) {
                html = stripIntegrity(html)
                html = injectMarker(html)
                if let reEncoded = html.data(using: .isoLatin1) { bodyData = reEncoded }
            }
        }

        var head = "HTTP/1.1 \(response.statusCode) \(reasonPhrase(response.statusCode))\r\n"
        for (key, value) in response.allHeaderFields {
            let name = String(describing: key)
            if dropResponseHeaders.contains(name.lowercased()) { continue }
            head += "\(name): \(String(describing: value))\r\n"
        }
        for line in setCookieHeaderLines(from: response) {
            head += line + "\r\n"
        }
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var out = Data(head.utf8)
        out.append(bodyData)
        return out
    }

    /// `HTTPURLResponse.allHeaderFields` collapses multiple `Set-Cookie`
    /// headers into a single comma-joined string — printing that directly (as
    /// the generic header loop above would) mangles every cookie after the
    /// first, since cookie attributes like `Expires` also contain commas.
    /// `HTTPCookie.cookies(withResponseHeaderFields:for:)` is Foundation's own
    /// cookie-aware parser for exactly this comma-joined shape, so it splits
    /// the cookies correctly; each one is then re-emitted as its own
    /// `Set-Cookie:` line.
    private static func setCookieHeaderLines(from response: HTTPURLResponse) -> [String] {
        guard let url = response.url else { return [] }
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            fields[String(describing: key)] = String(describing: value)
        }
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).map(setCookieLine)
    }

    private static func setCookieLine(for cookie: HTTPCookie) -> String {
        var parts = ["\(cookie.name)=\(cookie.value)"]
        if !cookie.path.isEmpty { parts.append("Path=\(cookie.path)") }
        if !cookie.domain.isEmpty { parts.append("Domain=\(cookie.domain)") }
        if let expires = cookie.expiresDate {
            parts.append("Expires=\(cookieDateFormatter.string(from: expires))")
        }
        if cookie.isHTTPOnly { parts.append("HttpOnly") }
        return "Set-Cookie: " + parts.joined(separator: "; ")
    }

    private static let cookieDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    private static func stripIntegrity(_ html: String) -> String {
        var result = html
        result = result.replacingOccurrences(of: "\\sintegrity=\"[^\"]*\"", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\sintegrity='[^']*'", with: "", options: .regularExpression)
        return result
    }

    private static func injectMarker(_ html: String) -> String {
        let marker = "<script>window.__fslProxyRewrite=1;</script>"
        if let headTag = html.range(of: "<head", options: .caseInsensitive),
           let close = html.range(of: ">", range: headTag.lowerBound..<html.endIndex) {
            var result = html
            result.insert(contentsOf: marker, at: close.upperBound)
            return result
        }
        return marker + html
    }

    private static func reasonPhrase(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 303: return "See Other"
        case 304: return "Not Modified"
        case 307: return "Temporary Redirect"
        case 308: return "Permanent Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}
