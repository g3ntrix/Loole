import Foundation
import SwiftUI

enum AppTheme: String, Codable, CaseIterable {
    case light, dark, system
    
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark:  return .dark
        case .system: return nil
        }
    }
}

struct AppSettings: Equatable {
    var credentialsFilename: String = "credentials.json"
    var folderID: String = ""
    var listenHost: String = "127.0.0.1"   // "127.0.0.1" (Local) or "0.0.0.0" (LAN)
    var listenPort: Int = 1080
    var useSystemProxy: Bool = false
    var setupComplete: Bool = false
    var serverSetupComplete: Bool = false
    var theme: AppTheme = .system
    var clientID: String = ""

    static let `default` = AppSettings()

    /// Returns a slugified, collision-resistant profile name derived from
    /// the local hostname (with a short random suffix for uniqueness). Used
    /// once during first setup; persisted thereafter.
    static func generateClientID() -> String {
        let raw = ProcessInfo.processInfo.hostName
            .lowercased()
            .replacingOccurrences(of: ".local", with: "")
        let slug = raw.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .reduce("") { $0 + String($1) }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = slug.isEmpty ? "client" : String(slug.prefix(24))
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        return "\(base)-\(suffix)"
    }

    var listenAddr: String { "\(listenHost):\(listenPort)" }

    var isLAN: Bool {
        get { listenHost == "0.0.0.0" }
        set { listenHost = newValue ? "0.0.0.0" : "127.0.0.1" }
    }

    var socksPort: Int { listenPort }
    var socksHost: String { listenHost }

    func makeClientConfig() -> [String: Any] {
        [
            "listen_addr": listenAddr,
            "client_id": clientID,
            "storage_type": "google",
            "google_folder_id": folderID,
            "transport": [
                "TargetIP": "216.239.38.120:443",
                "SNI": "google.com",
                "HostHeader": "www.googleapis.com",
                "InsecureSkipVerify": false
            ]
        ]
    }

    func makeServerConfig() -> [String: Any] {
        [
            "storage_type": "google",
            "google_folder_id": folderID
        ]
    }
}

extension AppSettings: Codable {
    enum CodingKeys: String, CodingKey {
        case credentialsFilename, folderID
        case listenHost, listenPort
        case useSystemProxy, setupComplete, serverSetupComplete
        case theme
        case clientID
        case listenAddr   // legacy — only read during migration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        credentialsFilename = (try? c.decode(String.self, forKey: .credentialsFilename)) ?? "credentials.json"
        folderID            = (try? c.decode(String.self, forKey: .folderID)) ?? ""
        useSystemProxy      = (try? c.decode(Bool.self,   forKey: .useSystemProxy)) ?? false
        setupComplete       = (try? c.decode(Bool.self,   forKey: .setupComplete))  ?? false
        serverSetupComplete = (try? c.decode(Bool.self,   forKey: .serverSetupComplete)) ?? false
        theme               = (try? c.decode(AppTheme.self, forKey: .theme)) ?? .system
        clientID            = (try? c.decode(String.self,   forKey: .clientID)) ?? ""

        // Prefer new split fields; fall back to old listenAddr string.
        if let host = try? c.decode(String.self, forKey: .listenHost) {
            listenHost = host
            listenPort = (try? c.decode(Int.self, forKey: .listenPort)) ?? 1080
        } else if let addr = try? c.decode(String.self, forKey: .listenAddr) {
            let parts = addr.split(separator: ":").map(String.init)
            listenHost = parts.first ?? "127.0.0.1"
            listenPort = parts.last.flatMap(Int.init) ?? 1080
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(credentialsFilename, forKey: .credentialsFilename)
        try c.encode(folderID,            forKey: .folderID)
        try c.encode(listenHost,          forKey: .listenHost)
        try c.encode(listenPort,          forKey: .listenPort)
        try c.encode(useSystemProxy,      forKey: .useSystemProxy)
        try c.encode(setupComplete,       forKey: .setupComplete)
        try c.encode(serverSetupComplete, forKey: .serverSetupComplete)
        try c.encode(theme,               forKey: .theme)
        try c.encode(clientID,            forKey: .clientID)
    }
}
