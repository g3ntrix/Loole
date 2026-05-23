import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                // Hero header
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .cornerRadius(16)
                    Text("Loole")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("Tunnels traffic through Google Drive")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

                // Status card
                statusCard

                // Diagnostics (while running)
                if app.status.isRunning {
                    HStack(spacing: 16) {
                        diagnosticItem(
                            label: "SERVER LOCATION",
                            value: app.serverLocation ?? (app.isTestingLatency ? "Checking..." : "Unknown"),
                            icon: "mappin.and.ellipse"
                        )
                        diagnosticItem(
                            label: "LATENCY",
                            value: latencyDisplay,
                            icon: "timer"
                        )
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Live Speed
                if app.status.isRunning {
                     HStack(spacing: 16) {
                        speedItem(label: "DOWNLOAD", value: formatSpeed(app.downloadSpeed), total: formatBytes(app.totalRX), icon: "arrow.down")
                        speedItem(label: "UPLOAD", value: formatSpeed(app.uploadSpeed), total: formatBytes(app.totalTX), icon: "arrow.up")
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Connect / Disconnect
                connectButton

                // Config info
                statsCard

                Spacer(minLength: 40)
            }
            .padding(32)
        }
        .animation(.spring(), value: app.status)
        .animation(.spring(), value: app.serverLocation)
    }

    // MARK: - Latency display

    private var latencyDisplay: String {
        if app.isTestingLatency && app.latency == nil { return "Testing..." }
        guard let l = app.latency else { return "N/A" }
        return l > 1.0 ? String(format: "%.1f s", l) : String(format: "%.0f ms", l * 1000)
    }

    // MARK: - Sub-views

    private func diagnosticItem(label: String, value: String, icon: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                    Text(label)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Text(value)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusCard: some View {
        Card {
            HStack(spacing: 20) {
                StatusDot(color: app.status.isRunning ? .green : .orange, animated: app.status.isRunning)

                VStack(alignment: .leading, spacing: 4) {
                    Text(app.status.label)
                        .font(.system(size: 18, weight: .bold, design: .rounded))

                    if let start = app.startedAt {
                        Text("Active since \(start.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else if case .error(let msg) = app.status {
                        Text(msg)
                            .font(.system(size: 11))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                }
                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    Toggle("System Proxy", isOn: Binding(
                        get: { app.settings.useSystemProxy },
                        set: { val in Task { await app.setSystemProxy(val) } }
                    ))
                    .toggleStyle(.switch)
                    .font(.system(size: 12, weight: .medium))

                    if app.status.isRunning {
                        Button {
                            Task { await app.testConnection() }
                        } label: {
                            if app.isTestingLatency {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Refresh", systemImage: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .medium))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(app.isTestingLatency)
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }

    private var connectButton: some View {
        Button {
            Task {
                if app.status.isRunning { await app.stop() }
                else { await app.start() }
            }
        } label: {
            ZStack {
                if app.status.isTransitioning {
                    ProgressView().controlSize(.small)
                } else {
                    Text(app.status.isRunning ? "Disconnect" : "Connect")
                        .font(.system(size: 15, weight: .bold))
                }
            }
            .frame(width: 200, height: 48)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(app.status.isRunning ? Color.red.opacity(0.8) : Color.accentColor))
            .foregroundColor(.white) // Keep white for prominent button regardless of theme
        }
        .buttonStyle(.plain)
        .disabled(app.status.isTransitioning)
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CONFIGURATION")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            Card {
                VStack(spacing: 12) {
                    statRow(label: "SOCKS5 Address", value: app.settings.listenAddr)
                    statRow(label: "Listen Mode",    value: app.settings.isLAN ? "LAN (shared)" : "Local only")
                    if app.settings.isLAN, let ip = AppState.getLANIPAddress() {
                        statRow(label: "LAN IP", value: ip)
                    }
                }
            }
        }
        .padding(.top, 12)
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(.primary)
        }
    }

    private func speedItem(label: String, value: String, total: String, icon: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(icon == "arrow.down" ? Color.blue : Color.green)
                    Text(label)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                
                HStack(alignment: .bottom, spacing: 4) {
                    Text(value.split(separator: " ").first ?? "")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(value.split(separator: " ").last ?? "")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 2)
                }
                
                Text("\(total) total")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 { return String(format: "%.0f B/s", bytesPerSec) }
        let kb = bytesPerSec / 1024
        if kb < 1024 { return String(format: "%.1f KB/s", kb) }
        let mb = kb / 1024
        return String(format: "%.1f MB/s", mb)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        if b < 1024 { return "\(bytes) B" }
        let kb = b / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        let gb = mb / 1024
        return String(format: "%.2f GB", gb)
    }
}
