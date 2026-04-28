import Foundation
import AppKit

/// Builds the server deployment zip that the user uploads to their Linux server.
///
/// Two modes:
/// - `.firstTimeServer`: includes the server binary plus this device's profile.
///   Layout in zip:
///     server
///     loole/profiles/<clientID>/{server_config.json, credentials.json, credentials.json.token}
///     run.sh
///   Server runs with `./server -d /root/loole/profiles`.
///
/// - `.addClient`: profile-only zip (no binary). Layout:
///     <clientID>/{server_config.json, credentials.json, credentials.json.token}
///   Admin extracts into the existing `/root/loole/profiles/` and the running
///   server hot-loads it (no restart needed).
enum ServerPackager {

    enum Mode {
        case firstTimeServer
        case addClient
    }

    enum PackageError: LocalizedError {
        case unknownArch(String)
        case binaryNotFound(String)
        case missingClientID
        case packagingFailed(String)

        var errorDescription: String? {
            switch self {
            case .unknownArch(let a):     return "Unrecognized architecture: \(a)"
            case .binaryNotFound(let b):  return "Server binary '\(b)' not found in app bundle."
            case .missingClientID:        return "Client ID is missing — restart the app to regenerate it."
            case .packagingFailed(let m): return "Packaging failed: \(m)"
            }
        }
    }

    /// Parses `uname -a` output and returns "amd64" or "arm64".
    static func detectArch(from unameOutput: String) -> String? {
        let lower = unameOutput.lowercased()
        if lower.contains("x86_64") || lower.contains("amd64") { return "amd64" }
        if lower.contains("aarch64") || lower.contains("arm64") { return "arm64" }
        return nil
    }

    /// Creates the deployment zip on the Desktop and returns its URL.
    /// `arch` is required for `.firstTimeServer`; ignored otherwise.
    static func buildPackage(
        mode: Mode,
        arch: String?,
        settings: AppSettings,
        store: ConfigStore
    ) throws -> URL {
        let clientID = settings.clientID
        guard !clientID.isEmpty else { throw PackageError.missingClientID }

        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("loole-server-pkg-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // Write the canonical server_config.json once; we copy it into the right slot.
        _ = try store.writeServerConfig(settings)
        let serverConfigSrc = store.appSupportDir.appendingPathComponent("server_config.json")

        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let zipURL: URL

        switch mode {
        case .firstTimeServer:
            guard let arch = arch else { throw PackageError.unknownArch("nil") }
            let binaryName = "loole-server-linux-\(arch)"
            guard let binaryURL = Bundle.main.url(forResource: binaryName, withExtension: nil) else {
                throw PackageError.binaryNotFound(binaryName)
            }

            // server binary at root
            let serverDest = tmp.appendingPathComponent("server")
            try fm.copyItem(at: binaryURL, to: serverDest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverDest.path)

            // profile dir under loole/profiles/<clientID>/
            let profileDir = tmp
                .appendingPathComponent("loole", isDirectory: true)
                .appendingPathComponent("profiles", isDirectory: true)
                .appendingPathComponent(clientID, isDirectory: true)
            try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
            try copyProfileFiles(into: profileDir, serverConfig: serverConfigSrc, store: store, fm: fm)

            // run.sh convenience script
            let runSh = """
            #!/bin/bash
            chmod +x ./server
            ./server -d ./loole/profiles
            """
            try runSh.write(to: tmp.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)

            zipURL = desktop.appendingPathComponent("loole-server.zip")

        case .addClient:
            // Top-level <clientID>/ subdir so admin can `unzip -d /root/loole/profiles/`.
            let profileDir = tmp.appendingPathComponent(clientID, isDirectory: true)
            try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
            try copyProfileFiles(into: profileDir, serverConfig: serverConfigSrc, store: store, fm: fm)

            zipURL = desktop.appendingPathComponent("loole-profile-\(clientID).zip")
        }

        if fm.fileExists(atPath: zipURL.path) { try fm.removeItem(at: zipURL) }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.arguments = ["-r", zipURL.path, "."]
        task.currentDirectoryURL = tmp
        let errPipe = Pipe()
        task.standardError = errPipe
        try task.run()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            let errMsg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw PackageError.packagingFailed(errMsg)
        }

        return zipURL
    }

    private static func copyProfileFiles(into profileDir: URL, serverConfig: URL, store: ConfigStore, fm: FileManager) throws {
        try fm.copyItem(at: serverConfig, to: profileDir.appendingPathComponent("server_config.json"))
        if store.credentialsExist() {
            try fm.copyItem(at: store.credentialsURL, to: profileDir.appendingPathComponent("credentials.json"))
        }
        if store.tokenExists() {
            try fm.copyItem(at: store.tokenURL, to: profileDir.appendingPathComponent("credentials.json.token"))
        }
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Returns deploy steps tailored to the package mode.
    static func deploymentCommands(
        mode: Mode,
        zipURL: URL,
        clientID: String,
        serverIP: String,
        includeSSH: Bool,
        serverPassword: String? = nil
    ) -> [(label: String, code: String)] {
        let localPath = zipURL.path
        let target = serverIP.isEmpty ? "YOUR_SERVER_IP" : serverIP
        let user = "root"
        let zipName = (zipURL.lastPathComponent)

        let sshCmd: String
        let scpCmd: String
        if let pass = serverPassword, !pass.isEmpty {
            sshCmd = "sshpass -p '\(pass)' ssh"
            scpCmd = "sshpass -p '\(pass)' scp"
        } else {
            sshCmd = "ssh"
            scpCmd = "scp"
        }

        switch mode {
        case .firstTimeServer:
            if !includeSSH {
                return [
                    (label: "1. Upload to Server",
                     code: "\(scpCmd) \"\(localPath)\" \(user)@\(target):/root/"),
                    (label: "2. Install Unzip & Extract",
                     code: "apt-get update && apt-get install -y unzip && cd /root && unzip -o \(zipName) && chmod +x server"),
                    (label: "3. Run (Background)",
                     code: "cd /root && nohup ./server -d /root/loole/profiles > loole.log 2>&1 &"),
                    (label: "4. Show Logs",
                     code: "tail -f /root/loole.log"),
                    (label: "5. Terminate",
                     code: "pkill -f '^./server'")
                ]
            }
            return [
                (label: "1. Upload to Server",
                 code: "\(scpCmd) \"\(localPath)\" \(user)@\(target):/root/"),
                (label: "2. Install Unzip & Extract",
                 code: "\(sshCmd) \(user)@\(target) 'apt-get update && apt-get install -y unzip && cd /root && unzip -o \(zipName) && chmod +x server'"),
                (label: "3. Run (Background)",
                 code: "\(sshCmd) \(user)@\(target) 'cd /root && nohup ./server -d /root/loole/profiles > loole.log 2>&1 &'"),
                (label: "4. Show Logs",
                 code: "\(sshCmd) \(user)@\(target) 'tail -f /root/loole.log'"),
                (label: "5. Terminate",
                 code: "\(sshCmd) \(user)@\(target) 'pkill -f ./server'")
            ]

        case .addClient:
            // No restart needed — the server polls /root/loole/profiles every 5s.
            if !includeSSH {
                return [
                    (label: "1. Upload to Server",
                     code: "\(scpCmd) \"\(localPath)\" \(user)@\(target):/root/"),
                    (label: "2. Extract into profiles dir",
                     code: "mkdir -p /root/loole/profiles && cd /root && unzip -o \(zipName) -d /root/loole/profiles/"),
                    (label: "3. Verify (within ~5s, server picks up the new profile)",
                     code: "tail -n 20 /root/loole.log")
                ]
            }
            return [
                (label: "1. Upload to Server",
                 code: "\(scpCmd) \"\(localPath)\" \(user)@\(target):/root/"),
                (label: "2. Extract into profiles dir",
                 code: "\(sshCmd) \(user)@\(target) 'mkdir -p /root/loole/profiles && cd /root && unzip -o \(zipName) -d /root/loole/profiles/'"),
                (label: "3. Verify (within ~5s, server picks up the new profile)",
                 code: "\(sshCmd) \(user)@\(target) 'tail -n 20 /root/loole.log'")
            ]
        }
    }
}
