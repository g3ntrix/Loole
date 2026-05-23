import Foundation

/// Spawns and supervises the bundled `loole-client` Go binary.
/// The binary reads its client_config.json via `-c` and credentials via `-gc`.
final class CoreManager {
    var onLog: ((LogLine) -> Void)?
    var onStatus: ((AppState.Status) -> Void)?
    var onSpeedUpdate: ((UInt64, UInt64) -> Void)?

    private let logLock = NSLock()
    private var captureLogs = false
    private var process: Process?
    private var pipe: Pipe?
    private var userInitiatedStop = false
    private var lastExitStatus: Int32?

    func setLogCaptureEnabled(_ enabled: Bool) {
        logLock.lock()
        captureLogs = enabled
        logLock.unlock()
    }

    func start(settings: AppSettings, credentialsURL: URL) async throws {
        await stop()

        let hostArch = machineArch()
        guard let clientURL = resolveBinary("loole-client-\(hostArch)") else {
            throw NSError(domain: "Loole", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "loole-client binary for \(hostArch) not found in app bundle."
            ])
        }

        let store = ConfigStore()
        let configURL = try store.writeClientConfig(settings)
        lastExitStatus = nil

        stripQuarantine(at: clientURL)

        log("[CoreManager] Launching \(clientURL.lastPathComponent) (\(hostArch))\n")

        let p = Process()
        p.executableURL = clientURL
        p.arguments = ["-c", configURL.path, "-gc", credentialsURL.path]
        p.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ]

        let out = Pipe()
        p.standardOutput = out
        p.standardError  = out

        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            if let data = try? out.fileHandleForReading.readToEnd(), !data.isEmpty {
                self.log(String(data: data, encoding: .utf8) ?? "")
            }
            out.fileHandleForReading.readabilityHandler = nil
            self.process = nil
            self.pipe = nil

            let initiated = self.userInitiatedStop
            self.userInitiatedStop = false
            let status = proc.terminationStatus
            self.lastExitStatus = status
            let cleanSignal = proc.terminationReason == .uncaughtSignal &&
                              (status == SIGTERM || status == SIGKILL)

            if initiated || status == 0 || cleanSignal {
                self.onStatus?(.stopped)
            } else {
                self.log("[loole-client exited with status \(status)]\n")
                self.onStatus?(.error("Client exited (\(status))"))
            }
        }

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            let text = String(data: chunk, encoding: .utf8) ?? ""
            self?.log(text)
            self?.parseStats(text)
        }

        try p.run()
        process = p
        pipe = out

        let host = settings.socksHost == "0.0.0.0" ? "127.0.0.1" : settings.socksHost
        let ready = await waitForPort(host: host, port: settings.socksPort, timeout: 20)
        if !ready {
            if process != nil {
                throw NSError(domain: "Loole", code: 11, userInfo: [
                    NSLocalizedDescriptionKey: "SOCKS5 listener on \(host):\(settings.socksPort) didn't come up. Enable Logs and retry if you need details."
                ])
            }
            let status = lastExitStatus.map { " (\($0))" } ?? ""
            throw NSError(domain: "Loole", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "loole-client exited before the SOCKS5 listener was ready\(status). Enable Logs and retry if you need details."
            ])
        }
        log("[CoreManager] Ready. SOCKS5 on \(host):\(settings.socksPort)\n")
        onStatus?(.running)
    }

    func stop() async {
        guard let p = process, p.isRunning else { return }
        userInitiatedStop = true
        p.terminate()
        for _ in 0..<30 {
            if process == nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if let p = process, p.isRunning { kill(p.processIdentifier, SIGKILL) }
        pipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        pipe = nil
    }

    // MARK: - Helpers

    private func waitForPort(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if canConnect(host: host, port: port) { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func canConnect(host: String, port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        let ip = host == "0.0.0.0" ? "127.0.0.1" : host
        ip.withCString { _ = inet_pton(AF_INET, $0, &addr.sin_addr) }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func machineArch() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        let m = String(cString: buf)
        if m.hasPrefix("arm") { return "arm64" }
        return "x86_64"
    }

    private func resolveBinary(_ name: String) -> URL? {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    private func stripQuarantine(at url: URL) {
        let path = (url.path as NSString).fileSystemRepresentation
        _ = removexattr(path, "com.apple.quarantine", 0x0001)
        _ = removexattr(path, "com.apple.provenance", 0x0001)
    }

    private func log(_ text: String) {
        logLock.lock()
        let enabled = captureLogs
        logLock.unlock()
        guard enabled else { return }
        onLog?(LogLine(stream: .stdout, text: text))
    }

    private func parseStats(_ text: String) {
        // Look for STATS|TX:123|RX:456
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("STATS|TX:") {
                let parts = line.components(separatedBy: "|")
                var tx: UInt64 = 0
                var rx: UInt64 = 0
                for part in parts {
                    if part.hasPrefix("TX:") {
                        tx = UInt64(part.dropFirst(3)) ?? 0
                    } else if part.hasPrefix("RX:") {
                        rx = UInt64(part.dropFirst(3)) ?? 0
                    }
                }
                onSpeedUpdate?(tx, rx)
            }
        }
    }
}
