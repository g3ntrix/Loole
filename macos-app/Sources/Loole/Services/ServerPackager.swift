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
        exportInstructions: Bool,
        settings: AppSettings,
        store: ConfigStore
    ) throws -> (zipURL: URL, instructionsURL: URL?) {
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
        let instructionsURL: URL?

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let timestamp = formatter.string(from: Date())

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
            pkill -f "[.]/server -d /root/loole/profiles" 2>/dev/null || true
            chmod +x ./server
            ./server -d ./loole/profiles
            """
            try runSh.write(to: tmp.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)

            let name = "loole-server-\(clientID)-\(timestamp)"
            zipURL = desktop.appendingPathComponent("\(name).zip")
            instructionsURL = exportInstructions ? desktop.appendingPathComponent("\(name)-setup.txt") : nil

        case .addClient:
            // Top-level <clientID>/ subdir so admin can `unzip -d /root/loole/profiles/`.
            let profileDir = tmp.appendingPathComponent(clientID, isDirectory: true)
            try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
            try copyProfileFiles(into: profileDir, serverConfig: serverConfigSrc, store: store, fm: fm)

            let name = "loole-profile-\(clientID)-\(timestamp)"
            zipURL = desktop.appendingPathComponent("\(name).zip")
            instructionsURL = exportInstructions ? desktop.appendingPathComponent("\(name)-setup.txt") : nil
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

        // Export instructions if requested
        if let instructionsURL = instructionsURL {
            let content = serverSideInstructions(mode: mode, zipName: zipURL.lastPathComponent)
            try content.write(to: instructionsURL, atomically: true, encoding: .utf8)
        }

        return (zipURL, instructionsURL)
    }

    private static func serverSideInstructions(mode: Mode, zipName: String) -> String {
        switch mode {
        case .firstTimeServer:
            return """
            # Loole Server Setup Instructions
            # Run these commands in the directory where you uploaded \(zipName) (usually /root)

            # 1. Install dependencies and extract the bundle
            apt-get update && apt-get install -y unzip && unzip -o \(zipName) && chmod +x server

            # 2. Restart Loole server
            pkill -f "[.]/server -d /root/loole/profiles" 2>/dev/null || true
            nohup ./server -d /root/loole/profiles > loole.log 2>&1 &

            # 3. Verify startup
            sleep 2
            if pgrep -af './server -d /root/loole/profiles' >/dev/null; then
              echo "OK: Loole server process is running"
            else
              echo "ERROR: Loole server process is not running"
              exit 1
            fi
            if grep -q 'high-speed profile started' loole.log; then
              echo "OK: Loole profile loaded"
            else
              echo "WARN: Loole profile has not loaded yet; recent logs:"
              tail -n 40 loole.log
            fi

            # Optional: watch live logs
            tail -f loole.log
            """
        case .addClient:
            return """
            # Loole Profile Setup Instructions
            # IMPORTANT: Your server must already be running in multi-profile mode:
            #   ./server -d /root/loole/profiles
            # If it was deployed with an older single-profile setup (-c / -gc flags),
            # redeploy it first using a "First-time setup" zip from any of your devices.

            # Run these commands in the directory where you uploaded \(zipName)

            # 1. Ensure profiles directory exists
            mkdir -p /root/loole/profiles

            # 2. Extract this profile into the profiles directory
            unzip -o \(zipName) -d /root/loole/profiles/

            # 3. Verify the server picked it up
            sleep 6
            if pgrep -af './server -d /root/loole/profiles' >/dev/null; then
              echo "OK: Loole server process is running"
            else
              echo "ERROR: Loole server process is not running"
              exit 1
            fi
            if grep -q 'high-speed profile started' /root/loole.log; then
              echo "OK: Loole profile loaded"
            else
              echo "WARN: Loole profile has not loaded yet; recent logs:"
              tail -n 40 /root/loole.log
            fi

            echo "Profile added. If the server is in multi-profile mode, it loads within ~5 seconds."
            """
        }
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
        let stopPrevious = "pkill -f \"[.]/server -d /root/loole/profiles\" 2>/dev/null || true"
        let installAndRestart = "apt-get update && apt-get install -y unzip && cd /root && unzip -o \(zipName) && chmod +x server && { \(stopPrevious); } && nohup ./server -d /root/loole/profiles > loole.log 2>&1 &"
        let localVerify = "sleep 2; if pgrep -af \"[.]\\/server -d /root/loole/profiles\" >/dev/null; then echo \"OK: Loole server process is running\"; else echo \"ERROR: Loole server process is not running\"; exit 1; fi; if grep -q \"high-speed profile started\" /root/loole.log; then echo \"OK: Loole profile loaded\"; else echo \"WARN: Loole profile has not loaded yet; recent logs:\"; tail -n 40 /root/loole.log; fi"
        let remoteVerify = "\(sshCmd) \(user)@\(target) '\(localVerify)'"

        switch mode {
        case .firstTimeServer:
            if !includeSSH {
                return [
                    (label: "Upload",
                     code: "\(scpCmd) \"\(localPath)\" \(user)@\(target):/root/"),
                    (label: "Install & Restart",
                     code: installAndRestart),
                    (label: "Verify",
                     code: localVerify),
                    (label: "Optional: Watch Logs",
                     code: "tail -f /root/loole.log")
                ]
            }
            return [
                (label: "Upload",
                 code: "\(scpCmd) \"\(localPath)\" \(user)@\(target):/root/"),
                (label: "Install & Restart",
                 code: "\(sshCmd) \(user)@\(target) '\(installAndRestart)'"),
                (label: "Verify",
                 code: remoteVerify),
                (label: "Optional: Watch Logs",
                 code: "\(sshCmd) \(user)@\(target) 'tail -f /root/loole.log'")
            ]

        case .addClient:
            // No restart needed — the server polls /root/loole/profiles every 5s.
            if !includeSSH {
                return [
                    (label: "Upload",
                     code: "\(scpCmd) \"\(localPath)\" \(user)@\(target):/root/"),
                    (label: "Install Profile",
                     code: "mkdir -p /root/loole/profiles && cd /root && unzip -o \(zipName) -d /root/loole/profiles/"),
                    (label: "Verify",
                     code: "sleep 6; \(localVerify)")
                ]
            }
            return [
                (label: "Upload",
                 code: "\(scpCmd) \"\(localPath)\" \(user)@\(target):/root/"),
                (label: "Install Profile",
                 code: "\(sshCmd) \(user)@\(target) 'mkdir -p /root/loole/profiles && cd /root && unzip -o \(zipName) -d /root/loole/profiles/'"),
                (label: "Verify",
                 code: "\(sshCmd) \(user)@\(target) 'sleep 6; \(localVerify)'")
            ]
        }
    }
}
