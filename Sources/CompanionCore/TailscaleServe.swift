#if os(macOS)
import Foundation

/// Owns one foreground TCP mapping. Never resets the user's Serve configuration.
@MainActor public final class TailscaleServe {
    private var process: Process?
    private var output: Pipe?
    public init() {}
    private static func binary() throws -> URL {
        let candidates = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw CompanionError.server("找不到 Tailscale CLI，请安装 Tailscale 后重试。") }
        return URL(fileURLWithPath: path)
    }
    private func status() async throws -> JSONValue {
        let task = Process(); task.executableURL = try Self.binary(); task.arguments = ["serve", "status", "--json"]
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        let result = try await withCheckedThrowingContinuation { (wait: CheckedContinuation<(Int32, Data), Error>) in
            // Drain stdout while the CLI runs, so a large Serve configuration
            // cannot fill the pipe and deadlock the main actor.
            DispatchQueue.global(qos: .utility).async {
                do {
                    try task.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit(); wait.resume(returning:(task.terminationStatus,data))
                } catch { wait.resume(throwing:error) }
            }
        }
        guard result.0 == 0 else { throw CompanionError.server("无法读取 Tailscale Serve 状态，请确认 Tailscale 已连接。") }
        return try JSONDecoder().decode(JSONValue.self,from:result.1)
    }
    private func hasPort(_ value: JSONValue, _ port: UInt16) -> Bool {
        if case .object(let object) = value {
            if case .object(let tcp) = object["TCP"], tcp[String(port)] != nil { return true }
            return object.values.contains { hasPort($0,port) }
        }
        return value.array.contains { hasPort($0,port) }
    }
    public func start(localPort: UInt16, publicPort: UInt16 = 8765) async throws {
        guard process == nil, localPort > 0, publicPort > 0 else { throw CompanionError.invalidAddress }
        guard !hasPort(try await status(),publicPort) else { throw CompanionError.server("Tailscale Serve 的 \(publicPort) 端口已在使用，请先关闭占用它的服务。") }
        let child = Process(); child.executableURL = try Self.binary()
        child.arguments = ["serve", "--tcp=\(publicPort)", "--yes", "tcp://127.0.0.1:\(localPort)"]
        let pipe = Pipe(); child.standardOutput = pipe; child.standardError = pipe; child.standardInput = FileHandle.nullDevice
        process = child; output = pipe
        do {
            try child.run()
            for _ in 0..<30 {
                try await Task.sleep(for:.milliseconds(200))
                guard child.isRunning else {
                    let message = String(decoding:pipe.fileHandleForReading.readDataToEndOfFile().prefix(4096),as:UTF8.self)
                    throw CompanionError.server("Tailscale Serve 未开启：\(message)")
                }
                if hasPort(try await status(),publicPort) { return }
            }
            throw CompanionError.server("Tailscale Serve 未就绪。请在终端运行 tailscale serve --tcp=8765 tcp://127.0.0.1:8766 检查是否需要启用 Serve，然后关闭该命令并重试。")
        } catch { stop(); throw error }
    }
    public func stopAndWait() async {
        let child = process; stop()
        guard let child else { return }
        await withCheckedContinuation { wait in
            DispatchQueue.global(qos:.utility).async { child.waitUntilExit(); wait.resume() }
        }
    }
    public func stop() {
        if let process, process.isRunning { process.interrupt() }
        process = nil; output = nil
    }
}
#endif
