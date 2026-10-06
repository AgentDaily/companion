import Foundation
import Network
import Security

public enum FrameCodec {
    public static let maximumSize = 4 * 1024 * 1024
    public static func encode(_ packet: RelayPacket) throws -> Data {
        let body = try JSONEncoder().encode(packet)
        guard body.count <= maximumSize else { throw CompanionError.invalidFrame }
        var length = UInt32(body.count).bigEndian
        var data = Data(bytes: &length, count: 4); data.append(body); return data
    }
    public static func length(_ header: Data) throws -> Int {
        guard header.count == 4 else { throw CompanionError.invalidFrame }
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0, size <= maximumSize else { throw CompanionError.invalidFrame }
        return Int(size)
    }
    public static func parameters(key: String, nearby: Bool = false) throws -> NWParameters {
        guard key.count == 64, let secret = Data(hex: key) else { throw CompanionError.invalidKey }
        let tls = NWProtocolTLS.Options()
        // A fresh handshake must validate the current pairing key after rotation.
        sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, false)
        sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: 0x00A8)!)
        let identity = Data("quenda-companion-v1".utf8)
        let psk = secret.withUnsafeBytes { DispatchData(bytes: $0) }
        let pskID = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, psk as __DispatchData, pskID as __DispatchData)
        let tcp = NWProtocolTCP.Options(); tcp.enableKeepalive = true; tcp.keepaliveIdle = 30; tcp.keepaliveCount = 3; tcp.keepaliveInterval = 5
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = nearby
        return parameters
    }
}

@MainActor public final class FramedConnection {
    public let packets: AsyncThrowingStream<RelayPacket, Error>
    private let continuation: AsyncThrowingStream<RelayPacket, Error>.Continuation
    private let connection: NWConnection
    private let connectionTimeout: Duration
    private var ready: CheckedContinuation<Void, Error>?
    private var ended = false
    private let attemptID = String(UUID().uuidString.prefix(8))
    private var connectionReport: NWConnection.PendingDataTransferReport?
    private var lastPathSummary: String?

    public init(_ connection: NWConnection, connectionTimeout: Duration = .seconds(10)) {
        self.connection = connection
        self.connectionTimeout = connectionTimeout
        let pair = AsyncThrowingStream<RelayPacket, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        packets = pair.stream; continuation = pair.continuation
    }
    public convenience init(pairing: Pairing) throws {
        let connection = NWConnection(host: NWEndpoint.Host(pairing.host), port: NWEndpoint.Port(rawValue: pairing.port)!, using: try FrameCodec.parameters(key: pairing.key))
        self.init(connection)
    }
    public convenience init(endpoint: NWEndpoint, key: String) throws {
        // Bonjour peer-to-peer setup includes service resolution and radio link setup,
        // before TCP/TLS starts. Give that setup one bounded, uninterrupted attempt.
        let timeout: Duration
        if case .service = endpoint { timeout = .seconds(30) } else { timeout = .seconds(10) }
        let parameters = try FrameCodec.parameters(key: key, nearby: true)
        #if DEBUG
        if ProcessInfo.processInfo.environment["COMPANION_DIAGNOSTIC_AWDL_ONLY"] == "1" {
            parameters.prohibitedInterfaces = NearbyDiscovery.diagnosticExcludedInterfaces
        }
        #endif
        self.init(NWConnection(to: endpoint, using: parameters), connectionTimeout: timeout)
    }
    /// Keep discovery demand for a local Wi-Fi peer. Release it for USB,
    /// wired or routed paths so ordinary connections do not keep browsing.
    var needsNearbyDiscovery: Bool {
        guard let path = connection.currentPath else { return true }
        let host: NWEndpoint.Host?
        if case .hostPort(let value, _) = path.remoteEndpoint { host = value } else { host = nil }
        return Self.needsNearbyDiscovery(interfaceTypes: path.availableInterfaces.map(\.type), host: host)
    }
    static func needsNearbyDiscovery(interfaceTypes: [NWInterface.InterfaceType], host: NWEndpoint.Host?) -> Bool {
        guard !interfaceTypes.isEmpty else { return true }
        guard interfaceTypes.contains(.wifi) else { return false }
        switch host {
        case .ipv6(let address): return address.isLinkLocal
        case .ipv4(let address): return address.isLinkLocal
        default: return true // An unresolved path is not evidence that the lease is unnecessary.
        }
    }
    public func start() async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { wait in
                ready = wait
                connectionReport = connection.startDataTransferReport()
                connection.pathUpdateHandler = { [weak self] path in
                    Task { @MainActor in
                        guard let self, !self.ended else { return }
                        let summary = Self.pathSummary(path)
                        guard self.lastPathSummary != summary else { return }
                        self.lastPathSummary = summary
                        self.record(self.ready == nil ? "transport.path" : "transport.connect.path", summary)
                    }
                }
                record("transport.connect.start", "endpoint=" + Self.endpointKind(connection.endpoint) + " budget=\(connectionTimeout)")
                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        guard let self, !self.ended else { return }
                        switch state {
                        case .ready:
                            ConnectionDiagnostics.shared.record("transport.ready", self.connection.currentPath?.availableInterfaces.map(\.name).joined(separator: ",") ?? "")
                            self.collectConnectionReport()
                            self.ready?.resume(); self.ready = nil; self.readHeader()
                        case .preparing: self.record("transport.connect.preparing", Self.pathSummary(self.connection.currentPath))
                        case .waiting(let error): self.record("transport.waiting", String(describing: error) + " " + Self.pathSummary(self.connection.currentPath))
                        case .failed(let error):
                            ConnectionDiagnostics.shared.record("transport.failed", String(describing: error)); self.close(error)
                        case .cancelled: self.close(CompanionError.disconnected)
                        default: break
                        }
                    }
                }
                connection.start(queue: .main)
                let timeout = connectionTimeout
                Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    if let self, self.ready != nil {
                        self.record("transport.connect.timeout", Self.pathSummary(self.connection.currentPath))
                        self.close(CompanionError.timeout)
                    }
                }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.close(CancellationError()) } })
    }
    public func send(_ packet: RelayPacket) async throws {
        guard !ended else { throw CompanionError.disconnected }
        let data = try FrameCodec.encode(packet)
        try await withCheckedThrowingContinuation { (wait: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { wait.resume(throwing: error) } else { wait.resume() }
            })
        }
    }
    public func close(_ error: Error = CompanionError.disconnected) {
        guard !ended else { return }; ended = true
        record("transport.close", "errorType=\(String(describing: type(of: error))) " + Self.pathSummary(connection.currentPath))
        collectConnectionReport()
        ready?.resume(throwing: error); ready = nil
        continuation.finish(throwing: error); connection.cancel()
    }
    private func record(_ stage: String, _ detail: String) {
        ConnectionDiagnostics.shared.record(stage, "attempt=\(attemptID) " + detail)
    }
    /// Describe only endpoint types, never device names, IP addresses or ports.
    private static func endpointKind(_ endpoint: NWEndpoint?) -> String {
        guard let endpoint else { return "none" }
        switch endpoint {
        case .service(_, _, _, let interface): return "service(interface=\(interface?.name ?? "any"))"
        case .hostPort(let host, _):
            switch host {
            case .ipv4: return "ipv4"
            case .ipv6: return "ipv6"
            case .name: return "hostname"
            @unknown default: return "unknown-host"
            }
        default: return "other"
        }
    }
    private static func pathSummary(_ path: NWPath?) -> String {
        guard let path else { return "path=none" }
        let reason = path.status == .satisfied ? "none" : String(describing: path.unsatisfiedReason)
        return "status=\(path.status) reason=\(reason) interfaces=\(path.availableInterfaces.map(\.name).sorted().joined(separator: ",")) remote=\(endpointKind(path.remoteEndpoint)) ipv4=\(path.supportsIPv4) ipv6=\(path.supportsIPv6)"
    }
    private func collectConnectionReport() {
        guard let report = connectionReport else { return }
        connectionReport = nil
        let diagnostics = ConnectionDiagnostics.shared, id = attemptID
        report.collect(queue: .main) { report in
            Task { @MainActor in
                let paths = report.pathReports.map {
                    "interface=\($0.interface.name) sentIP=\($0.sentIPPacketCount) receivedIP=\($0.receivedIPPacketCount) sentTCP=\($0.sentTransportByteCount) receivedTCP=\($0.receivedTransportByteCount)"
                }.joined(separator: "; ")
                diagnostics.record("transport.connect.packets", "attempt=\(id) " + (paths.isEmpty ? "unavailable" : paths))
            }
        }
    }
    private func readHeader() {
        receive(count: 4) { [weak self] header in
            guard let self else { return }
            do {
                let length = try FrameCodec.length(header)
                self.receive(count: length) { [weak self] body in
                    guard let self else { return }
                    do {
                        let packet = try JSONDecoder().decode(RelayPacket.self, from: body)
                        if case .dropped = self.continuation.yield(packet) { self.close(CompanionError.server("接收队列已满，请重新连接。")); return }
                        self.readHeader()
                    } catch { self.close(CompanionError.invalidFrame) }
                }
            } catch { self.close(error) }
        }
    }
    private func receive(count: Int, accumulated: Data = Data(), complete: @escaping @MainActor (Data) -> Void) {
        guard !ended else { return }
        let remaining = count - accumulated.count
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, eof, error in
            Task { @MainActor in
                guard let self, !self.ended else { return }
                if let error { self.record("transport.receive.failed", String(describing: error)); self.close(error); return }
                var bytes = accumulated; if let data { bytes.append(data) }
                if bytes.count == count { complete(bytes) }
                else if eof || data?.isEmpty != false { self.record("transport.receive.end", "eof=\(eof) bytes=\(bytes.count) expected=\(count)"); self.close(CompanionError.disconnected) }
                else { self.receive(count: count, accumulated: bytes, complete: complete) }
            }
        }
    }
}
