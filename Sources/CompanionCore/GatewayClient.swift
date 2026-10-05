import Foundation

@MainActor public final class GatewayClient {
    public let baseURL: URL
    private let session: URLSession
    public init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config)
        }
    }
    public func request(method: String = "GET", path: String, body: Data? = nil) async throws -> APIReply {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL, url.host == baseURL.host, url.port == baseURL.port, url.scheme == baseURL.scheme else { throw CompanionError.invalidAddress }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CompanionError.server("Gateway 返回了无效响应。") }
        guard data.count <= FrameCodec.maximumSize / 2 else { throw CompanionError.server("响应过大，请减少消息页大小。") }
        return APIReply(status: response.statusCode, body: data)
    }
    public func channel(sessionID: String) throws -> GatewayChannel {
        guard RoutePolicy.validSessionID(sessionID), var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw CompanionError.invalidAddress }
        c.scheme = c.scheme == "https" ? "wss" : "ws"; c.path = "/ws/sessions/\(sessionID)"
        return GatewayChannel(url: c.url!)
    }
}

@MainActor public final class GatewayChannel {
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let delegate: SocketDelegate
    private var opening: CheckedContinuation<Void, Error>?
    private var closed = false
    private var reader: Task<Void, Never>?
    public init(url: URL) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
        delegate = SocketDelegate()
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = FrameCodec.maximumSize / 2
    }
    public func start() async throws -> AsyncThrowingStream<GatewayEvent, Error> {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (wait: CheckedContinuation<Void, Error>) in
                guard !closed else { wait.resume(throwing: CompanionError.disconnected); return }
                opening = wait
                delegate.onOpen = { [weak self] in self?.opening?.resume(); self?.opening = nil }
                delegate.onFailure = { [weak self] error in self?.close(error) }
                task.resume()
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    if let self, self.opening != nil { self.close(CompanionError.timeout) }
                }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.close(CancellationError()) } })
        let pair = AsyncThrowingStream<GatewayEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        reader = Task {
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    let data: Data
                    switch message { case .string(let text): data = Data(text.utf8); case .data(let bytes): data = bytes; @unknown default: continue }
                    let event = try JSONDecoder().decode(GatewayEvent.self, from: data)
                    if case .dropped = pair.continuation.yield(event) { throw CompanionError.server("流式消息积压，请重新连接。") }
                }
            } catch { pair.continuation.finish(throwing: error) }
        }
        pair.continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.close() } }
        return pair.stream
    }
    public func send(_ value: JSONValue) async throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        let data = try encoder.encode(value)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }
    public func close(_ error: Error = CompanionError.disconnected) {
        guard !closed else { return }; closed = true
        opening?.resume(throwing: error); opening = nil
        reader?.cancel(); reader = nil; task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel()
    }
}

public enum RoutePolicy {
    public static func validSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.count < 200 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
    public static func allows(method: String, path: String) -> Bool {
        guard path.hasPrefix("/api/"), !path.contains("%"), !path.contains(".."), !path.contains("\\"), let c = URLComponents(string: path), c.host == nil, c.fragment == nil else { return false }
        if method == "GET", ["/api/health", "/api/agents", "/api/workspaces", "/api/sessions"].contains(c.path) { return true }
        if method == "POST", ["/api/sessions", "/api/workspaces"].contains(c.path), c.query == nil { return true }
        if method == "GET", c.path == "/api/models" { return true }
        let modelParts = c.path.split(separator: "/").map(String.init)
        if modelParts.count == 4, modelParts.prefix(3) == ["api", "models", "settings"], validSessionID(modelParts[3]), c.query == nil, ["GET", "PUT"].contains(method) { return true }
        let parts = c.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "api", parts[1] == "sessions", validSessionID(parts[2]), method == "GET" else { return false }
        return parts.count == 3 || (parts.count == 4 && ["message-pages", "interactions"].contains(parts[3])) || (parts.count == 5 && parts[3] == "attachments" && validSessionID(parts[4]))
    }
}

@MainActor private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate {
    var onOpen: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { @MainActor in self.onOpen?() }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in self.onFailure?(error ?? CompanionError.disconnected) }
    }
}
