#if FECBOX_LOCAL && os(macOS)
import AppKit
import Foundation
import Libbox
import NetworkExtension

/// The upstream views retain their lifecycle API; the engine uses native utun instead of NEVPNManager.
@MainActor
public final class ExtensionProfile: ObservableObject {
    public static let controlKind = AppConfiguration.widgetControlKind
    public static let local = ExtensionProfile()
    public static let mock = ExtensionProfile(mock: true)

    @Published public var status: NEVPNStatus
    @Published public var connectedDate: Date?
    private let isMock: Bool
    private var process: Process?
    private var monitor: Task<Void, Never>?
    private var operation: UUID?
    private var lastError: Error?

    private init(mock: Bool = false) {
        isMock = mock
        status = mock ? .connected : .disconnected
        connectedDate = mock ? Date() : nil
    }

    public func register() {
        guard !isMock, monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                guard status == .connected else { continue }
                do {
                    let started = try await Self.startedAt()
                    connectedDate = Date(timeIntervalSince1970: Double(started) / 1000)
                } catch {
                    lastError = Self.backendError()
                    status = .disconnected
                    connectedDate = nil
                }
            }
        }
    }

    private static var configURL: URL { FilePath.sharedDirectory.appendingPathComponent("local-config.json") }
    private static var logURL: URL { FilePath.sharedDirectory.appendingPathComponent("local-service.log") }

    private func prepareConfiguration() async throws -> Bool {
        let selected = await SharedPreferences.selectedProfileID.get()
        guard let profile = try await ProfileManager.get(selected) else {
            throw Self.failure("Missing selected profile")
        }
        let content = try await profile.readAsync()
        guard content.utf8.count <= 2 * 1024 * 1024 else { throw Self.failure("Configuration exceeds 2 MiB") }
        try await BlockingIO.run {
            var error: NSError?
            LibboxCheckConfig(content, &error)
            if let error { throw error }
        }
        try FileManager.default.createDirectory(at: FilePath.sharedDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: FilePath.sharedDirectory.path)
        try Data(content.utf8).write(to: Self.configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.configURL.path)
        let config = try JSONSerialization.jsonObject(with: Data(content.utf8), options: [.json5Allowed]) as? [String: Any] ?? [:]
        let inbounds = config["inbounds"] as? [[String: Any]] ?? []
        let endpoints = config["endpoints"] as? [[String: Any]] ?? []
        return inbounds.contains { $0["type"] as? String == "tun" } || endpoints.contains { $0["system"] as? Bool == true }
    }

    public func start() async throws {
        guard !isMock, status == .disconnected else { return }
        let token = UUID()
        operation = token
        lastError = nil
        status = .connecting
        do {
            let needsAdmin = try await prepareConfiguration()
            guard let backend = Bundle.main.url(forAuxiliaryExecutable: "fecbox-local") else {
                throw Self.failure("Bundled FECBox backend is missing")
            }
            let arguments = ["--base", FilePath.sharedDirectory.path, "--parent", String(ProcessInfo.processInfo.processIdentifier), "--uid", String(getuid()), "--gid", String(getgid())]
            FileManager.default.createFile(atPath: Self.logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            if needsAdmin {
                let command = ([backend.path] + arguments).map(Self.shellQuote).joined(separator: " ") + " < /dev/null > " + Self.shellQuote(Self.logURL.path) + " 2>&1 &"
                try await BlockingIO.run {
                    let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    guard let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges") else {
                        throw Self.failure("Cannot request administrator authorization")
                    }
                    var error: NSDictionary?
                    script.executeAndReturnError(&error)
                    if let error { throw Self.failure(error[NSAppleScript.errorMessage] as? String ?? "Administrator authorization failed") }
                }
            } else {
                let child = Process()
                child.executableURL = backend
                child.arguments = arguments
                let log = try FileHandle(forWritingTo: Self.logURL)
                defer { try? log.close() }
                try log.truncate(atOffset: 0)
                child.standardOutput = log
                child.standardError = log
                child.standardInput = FileHandle.nullDevice
                try child.run()
                process = child
            }
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                do {
                    let started = try await Self.startedAt()
                    guard operation == token else {
                        try? await Self.closeBackend()
                        return
                    }
                    connectedDate = Date(timeIntervalSince1970: Double(started) / 1000)
                    status = .connected
                    register()
                    return
                } catch {
                    if let process, !process.isRunning { break }
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
            throw Self.backendError()
        } catch {
            operation = nil
            try? FileManager.default.removeItem(at: Self.configURL)
            process?.terminate()
            process = nil
            lastError = error
            status = .disconnected
            throw error
        }
    }

    public func stop() async throws {
        guard !isMock else { return }
        operation = nil
        status = .disconnecting
        do {
            try await Self.closeBackend()
            for _ in 0..<80 {
                if !FileManager.default.fileExists(atPath: FilePath.sharedDirectory.appendingPathComponent("command.sock").path) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            process = nil
            connectedDate = nil
            status = .disconnected
        } catch {
            try? FileManager.default.removeItem(at: Self.configURL)
            if process?.isRunning == true {
                process?.terminate()
            }
            status = .disconnected
            connectedDate = nil
            throw error
        }
    }

    public func reloadService() async throws {
        guard status == .connected else { return }
        _ = try await prepareConfiguration()
        try await BlockingIO.run {
            let client = LibboxNewStandaloneCommandClient()!
            defer { try? client.disconnect() }
            try client.serviceReload()
        }
    }

    public func restart() async throws {
        try await stop()
        try await start()
    }

    public func fetchProfile() async throws {}
    public func fetchLastDisconnectError() async throws { if let lastError { throw lastError } }
    public func updateProtocolConfiguration() async throws { throw Self.failure("Edit TUN routes in the sing-box configuration") }
    public func updateOnDemand(enabled: Bool, useDefaultRules: Bool) async throws { throw Self.failure("Network Extension on-demand rules are unavailable in the local backend") }
    public static func load() async throws -> ExtensionProfile? { local }
    public static func install() async throws {}

    private nonisolated static func startedAt() async throws -> Int64 {
        try await BlockingIO.run {
            let client = LibboxNewStandaloneCommandClient()!
            defer { try? client.disconnect() }
            var started: Int64 = 0
            try client.getStartedAt(&started)
            return started
        }
    }

    private nonisolated static func closeBackend() async throws {
        try await BlockingIO.run {
            let client = LibboxNewStandaloneCommandClient()!
            defer { try? client.disconnect() }
            try client.serviceClose()
        }
    }

    private nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func backendError() -> NSError {
        let data = (try? Data(contentsOf: logURL)) ?? Data()
        let text = String(decoding: data.suffix(16 * 1024), as: UTF8.self)
        return failure(text.isEmpty ? "Local backend did not start; check administrator authorization and the configuration" : text)
    }

    private nonisolated static func failure(_ message: String) -> NSError {
        NSError(domain: "FECBox.LocalBackend", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
