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
    private var ready: CheckedContinuation<Void, Error>?
    private var ended = false
    public init(_ connection: NWConnection) {
        self.connection = connection
        let pair = AsyncThrowingStream<RelayPacket, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        packets = pair.stream; continuation = pair.continuation
    }
    public convenience init(pairing: Pairing) throws {
        let connection = NWConnection(host: NWEndpoint.Host(pairing.host), port: NWEndpoint.Port(rawValue: pairing.port)!, using: try FrameCodec.parameters(key: pairing.key))
        self.init(connection)
    }
    public convenience init(endpoint: NWEndpoint, key: String) throws {
        self.init(NWConnection(to: endpoint, using: try FrameCodec.parameters(key: key, nearby: true)))
    }
    public func start() async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { wait in
                ready = wait
                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        guard let self, !self.ended else { return }
                        switch state {
                        case .ready:
                            self.ready?.resume(); self.ready = nil; self.readHeader()
                        case .failed(let error): self.close(error)
                        case .cancelled: self.close(CompanionError.disconnected)
                        default: break
                        }
                    }
                }
                connection.start(queue: .main)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    if let self, self.ready != nil { self.close(CompanionError.timeout) }
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
        ready?.resume(throwing: error); ready = nil
        continuation.finish(throwing: error); connection.cancel()
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
                if let error { self.close(error); return }
                var bytes = accumulated; if let data { bytes.append(data) }
                if bytes.count == count { complete(bytes) }
                else if eof || data?.isEmpty != false { self.close(CompanionError.disconnected) }
                else { self.receive(count: count, accumulated: bytes, complete: complete) }
            }
        }
    }
}
