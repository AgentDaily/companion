import Foundation
import SwiftUI
import CompanionCore

/// Owns the device link and its reconnect lifecycle, independently of any app.
@MainActor public final class DeviceConnectionStore: ObservableObject {
    @Published public private(set) var state = CompanionConnectionState.disconnected
    @Published public private(set) var pairing: Pairing?
    @Published public private(set) var applications: [CompanionApplication] = []
    @Published public private(set) var link: CompanionLink?
    @Published public private(set) var revision = 0
    @Published public private(set) var applicationRevisions: [String: Int] = [:]
    @Published public var error: String?
    private var attempt = 0
    private var candidate: CompanionLink?
    private var operation: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var suspended = false
    private let savePairing: @MainActor (Pairing) throws -> Void
    private let makeLink: @MainActor (Pairing) -> CompanionLink
    public var connected: Bool { link != nil }
    public var connecting: Bool { operation != nil }
    public init(pairing: Pairing? = nil, savePairing: @escaping @MainActor (Pairing) throws -> Void = { try CredentialStore.write($0.link, account: "phone-pairing") }, makeLink: @escaping @MainActor (Pairing) -> CompanionLink = { CompanionLink(pairing: $0) }) {
        self.pairing = pairing; self.savePairing = savePairing; self.makeLink = makeLink
    }
    public func loadPairing() {
        do {
            if let saved = try CredentialStore.read("phone-pairing") { pairing = try Pairing(link: saved) }
        } catch { self.error = error.localizedDescription }
    }
    public enum ReconnectReason: String { case manual, pairing, resume, refresh, recovery }
    public func pair(link: String) async throws {
        let credentials = try Pairing(link: link)
        let unchanged = pairing.map {
            $0.host == credentials.host && $0.port == credentials.port && $0.key == credentials.key &&
            $0.nearbyService?.lowercased() == credentials.nearbyService?.lowercased()
        } ?? false
        ConnectionDiagnostics.shared.record("device.pairing", unchanged ? "unchanged" : "changed")
        if unchanged {
            suspended = false
            if let operation { await operation.value }
            else if !connected { await reconnect(reason: .pairing) }
            return
        }
        try savePairing(credentials)
        pairing = credentials; applications = []; suspended = false
        await reconnect(reason: .pairing)
    }
    public func resume() async {
        suspended = false
        guard !connected, operation == nil else { return }
        await reconnect(reason: .resume)
    }
    /// Refresh application availability without discarding an authenticated device link.
    public func refresh() async {
        guard !suspended else { return }
        if let operation { await operation.value; return }
        guard let link else { await reconnect(reason: .refresh); return }
        let token = attempt
        do {
            let applications = try await link.applications()
            guard token == attempt, self.link === link, !suspended else { return }
            self.applications = applications; error = nil
        } catch {
            guard token == attempt, self.link === link, !suspended else { return }
            self.error = error.localizedDescription
        }
    }
    public func reconnect(reason: ReconnectReason = .manual) async {
        retry?.cancel(); retry = nil
        guard !suspended, let pairing else { return }
        ConnectionDiagnostics.shared.record("device.reconnect", "source=\(reason.rawValue) nearby=\(pairing.nearbyService != nil) remote=\(pairing.remoteHost != nil)")
        attempt += 1; let token = attempt
        operation?.cancel(); candidate?.onState = nil; candidate?.close(); link = nil; revision += 1
        state = pairing.nearbyService == nil ? .connectingRemote : .discovering; error = nil
        let candidate = makeLink(pairing); self.candidate = candidate
        candidate.onState = { [weak self] state in
            guard let self, self.attempt == token, !self.suspended else { return }
            self.state = state
            if state == .disconnected, self.link != nil {
                self.link = nil; self.revision += 1
                self.error = "与 Mac 的连接已中断，正在恢复。"
                self.scheduleRecovery()
            }
        }
        candidate.onApplicationsChanged = { [weak self, weak candidate] id in
            Task { @MainActor in
                guard let self, let candidate, self.attempt == token, self.link != nil else { return }
                do {
                    let applications = try await candidate.applications()
                    guard self.attempt == token, !self.suspended else { return }
                    self.applications = applications
                    if let id { self.applicationRevisions[id, default: 0] += 1 }
                } catch { if self.attempt == token { self.error = error.localizedDescription } }
            }
        }
        let task = Task {
            do {
                try await candidate.connect()
                let applications = try await candidate.applications()
                try Task.checkCancellation()
                guard attempt == token, !suspended else { candidate.close(); return }
                self.applications = applications; link = candidate; revision += 1; error = nil
                ConnectionDiagnostics.shared.record("device.catalog.ready", "count=\(applications.count)")
            } catch {
                guard attempt == token, !suspended else { return }
                self.error = error.localizedDescription; state = .disconnected; link = nil
            }
            if attempt == token { operation = nil; if link == nil { scheduleRecovery() } }
        }
        operation = task
        await task.value
    }
    public func suspend() {
        ConnectionDiagnostics.shared.record("device.suspend")
        suspended = true; attempt += 1
        operation?.cancel(); operation = nil; retry?.cancel(); retry = nil
        candidate?.onState = nil; candidate?.close(); candidate = nil
        link = nil; state = .disconnected; revision += 1
    }
    private func scheduleRecovery() {
        guard !suspended, retry == nil, pairing != nil else { return }
        retry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, !self.suspended else { return }
            self.retry = nil
            guard !self.connected, self.operation == nil else { return }
            await self.reconnect(reason: .recovery)
        }
    }
}
