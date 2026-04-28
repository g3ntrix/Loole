import Foundation
import Combine
import Darwin

@MainActor
final class AppState: ObservableObject {

    enum Tab: String, CaseIterable, Identifiable {
        case dashboard, logs, server, setup, settings, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .dashboard: return "Status"
            case .logs:      return "Output"
            case .server:    return "Deploy Server"
            case .setup:     return "Setup"
            case .settings:  return "Settings"
            case .about:     return "About"
            }
        }
        var symbol: String {
            switch self {
            case .dashboard: return "dot.radiowaves.left.and.right"
            case .logs:      return "terminal"
            case .server:    return "server.rack"
            case .setup:     return "gearshape.2"
            case .settings:  return "slider.horizontal.3"
            case .about:     return "info.circle"
            }
        }
    }

    // MARK: - Connection status

    enum Status: Equatable {
        case stopped
        case starting
        case running
        case stopping
        case error(String)

        var isRunning: Bool { if case .running = self { return true }; return false }
        var isTransitioning: Bool {
            switch self { case .starting, .stopping: return true; default: return false }
        }
        var label: String {
            switch self {
            case .stopped:        return "Not connected"
            case .starting:       return "Connecting…"
            case .running:        return "Connected"
            case .stopping:       return "Disconnecting…"
            case .error(let msg): return "Error: \(msg)"
            }
        }
    }

    // MARK: - Wizard step

    enum WizardStep: Int, Comparable {
        case credentials = 0
        case authorize   = 1
        case serverSetup = 2

        static func < (lhs: WizardStep, rhs: WizardStep) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    // MARK: - Published

    @Published var settings: AppSettings
    @Published var status: Status = .stopped
    @Published var logs: [LogLine] = []
    @Published var startedAt: Date?
    @Published var wizardStep: WizardStep = .credentials
    @Published var isWizardComplete: Bool = false
    @Published var serverLocation: String?
    @Published var latency: Double?
    @Published var isTestingLatency = false
    
    @Published var uploadSpeed: Double = 0
    @Published var downloadSpeed: Double = 0
    @Published var totalTX: UInt64 = 0
    @Published var totalRX: UInt64 = 0
    
    @Published var activeTab: Tab = .dashboard
    
    // Drafts for persistent UI state during refreshes
    @Published var settingsDraft: AppSettings?
    @Published var draftPort: String = ""
    @Published var draftPoll: String = ""
    @Published var draftFlush: String = ""

    private var lastTX: UInt64 = 0
    private var lastRX: UInt64 = 0
    private var lastStatsUpdate = Date()

    private let store = ConfigStore()
    private let core  = CoreManager()

    init() {
        var loaded = ConfigStore().loadSettings() ?? .default
        if loaded.clientID.isEmpty {
            loaded.clientID = AppSettings.generateClientID()
            ConfigStore().saveSettings(loaded)
        }
        self.settings = loaded
        self.isWizardComplete = loaded.setupComplete

        core.onLog = { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }
        core.onStatus = { [weak self] s in
            Task { @MainActor in self?.status = s }
        }
        core.onSpeedUpdate = { [weak self] tx, rx in
            Task { @MainActor in self?.updateSpeed(tx: tx, rx: rx) }
        }
    }

    // MARK: - Start / Stop

    func start() async {
        guard !settings.folderID.isEmpty else {
            status = .error("Complete the setup wizard first.")
            return
        }
        store.saveSettings(settings)
        status = .starting
        startedAt = Date()
        do {
            try await core.start(settings: settings, credentialsURL: store.credentialsURL)
            if settings.useSystemProxy {
                await applySystemProxy(true)
            }
            // Automatically test connection health after successful connect
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // Give core a second to settle
                await testConnection()
            }
        } catch {
            status = .error(error.localizedDescription)
            startedAt = nil
            await core.stop()
        }
    }

    func stop() async {
        status = .stopping
        if settings.useSystemProxy {
            await applySystemProxy(false)
        }
        await core.stop()
        startedAt = nil
        serverLocation = nil
        latency = nil
        uploadSpeed = 0
        downloadSpeed = 0
        totalTX = 0
        totalRX = 0
        lastTX = 0
        lastRX = 0
    }

    // MARK: - Diagnostics

    func testConnection() async {
        isTestingLatency = true
        let start = Date()
        
        // 1. Get location (implicitly tests connectivity)
        await refreshLocation()
        
        // 2. Simple latency check (measure time to hit a reliable endpoint)
        if let url = URL(string: "https://www.google.com/generate_204") {
            do {
                let session = URLSession(configuration: .ephemeral)
                _ = try await session.data(from: url)
                latency = Date().timeIntervalSince(start)
            } catch {
                latency = nil
            }
        }
        isTestingLatency = false
    }

    private func refreshLocation() async {
        guard let url = URL(string: "https://ipapi.co/json/") else { return }
        do {
            let session = URLSession(configuration: .ephemeral)
            let (data, _) = try await session.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let city = json["city"] as? String,
               let country = json["country_name"] as? String {
                serverLocation = "\(city), \(country)"
            }
        } catch {
            serverLocation = "Unknown"
        }
    }

    // MARK: - System proxy

    func setSystemProxy(_ on: Bool) async {
        settings.useSystemProxy = on
        store.saveSettings(settings)
        guard status.isRunning else { return }
        await applySystemProxy(on)
    }

    private func applySystemProxy(_ on: Bool) async {
        let result: SystemProxy.Result
        if on {
            let host = settings.socksHost == "0.0.0.0" ? "127.0.0.1" : settings.socksHost
            result = await SystemProxy.enable(host: host, port: settings.socksPort)
        } else {
            result = await SystemProxy.disable()
        }
        if case .failed(let msg) = result {
            appendLog(LogLine(stream: .system, text: "⚠ System proxy: \(msg)\n"))
        }
    }

    // MARK: - Settings

    func saveSettings() { store.saveSettings(settings) }

    func completeWizard() {
        settings.setupComplete = true
        store.saveSettings(settings)
        isWizardComplete = true
    }

    func resetWizard() async {
        if status.isRunning { await stop() }
        settings.setupComplete = false
        settings.folderID = ""
        store.saveSettings(settings)
        try? FileManager.default.removeItem(at: store.credentialsURL)
        try? FileManager.default.removeItem(at: store.tokenURL)
        isWizardComplete = false
    }

    private func updateSpeed(tx: UInt64, rx: UInt64) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastStatsUpdate)
        guard elapsed >= 0.5 else { return } // Avoid jitter

        if lastTX > 0 {
            uploadSpeed = Double(tx - lastTX) / elapsed
        }
        if lastRX > 0 {
            downloadSpeed = Double(rx - lastRX) / elapsed
        }

        lastTX = tx
        lastRX = rx
        totalTX = tx
        totalRX = rx
        lastStatsUpdate = now
    }

    // MARK: - Logs

    func appendLog(_ line: LogLine) {
        if logs.count > 3000 { logs.removeFirst(500) }
        logs.append(line)
    }

    func clearLogs() { logs.removeAll() }

    // MARK: - Network utilities

    static func getLANIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let iface = ptr {
            defer { ptr = iface.pointee.ifa_next }
            let name = String(cString: iface.pointee.ifa_name)
            // Only physical WiFi/Ethernet (en0, en1, …) — skip loopback, VPN (utun*), bridges, etc.
            guard name.hasPrefix("en"),
                  let addr = iface.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                _ = inet_ntop(AF_INET, &$0.pointee.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            }
            let ip = String(cString: buf)
            if !ip.isEmpty && ip != "0.0.0.0" { return ip }
        }
        return nil
    }
}

struct LogLine: Identifiable, Equatable {
    let id = UUID()
    let timestamp = Date()
    let stream: Stream
    let text: String
    enum Stream { case stdout, stderr, system }
}
