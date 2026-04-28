import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    
    @State private var saved = false
    @State private var showResetConfirm = false
    @State private var lanIP: String? = nil

    private var isRunning: Bool { app.status.isRunning }
    private var hasChanges: Bool { app.settingsDraft != app.settings }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {

                // MARK: Network
                section("Network") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("SOCKS5 Listen Mode")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 0) {
                            modeButton(label: "Local", selected: app.settingsDraft?.listenHost == "127.0.0.1") {
                                app.settingsDraft?.listenHost = "127.0.0.1"
                            }
                            modeButton(label: "LAN", selected: app.settingsDraft?.listenHost == "0.0.0.0") {
                                app.settingsDraft?.listenHost = "0.0.0.0"
                                if lanIP == nil { lanIP = AppState.getLANIPAddress() }
                            }
                        }
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1))

                        if app.settingsDraft?.listenHost == "0.0.0.0" {
                            HStack(spacing: 6) {
                                Image(systemName: "wifi")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.accentColor)
                                Text("Your LAN IP:")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text(lanIP ?? "N/A")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.primary)
                            }
                            Text("Other devices on your network can use this address as their SOCKS5 proxy.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Only this Mac can use the proxy.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider().opacity(0.15).padding(.vertical, 4)

                    settingRow(label: "SOCKS5 Port") {
                        TextField("1080", text: $app.draftPort)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .font(.system(size: 12, design: .monospaced))
                            .onChange(of: app.draftPort) { v in
                                if let n = Int(v), (1...65535).contains(n) { app.settingsDraft?.listenPort = n }
                            }
                    }
                }

                // MARK: Timing & Appearance
                HStack(alignment: .top, spacing: 20) {
                    section("Timing") {
                        VStack(alignment: .leading, spacing: 14) {
                            settingRow(label: "Poll Rate") {
                                HStack(spacing: 6) {
                                    TextField("200", text: $app.draftPoll)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 60)
                                        .font(.system(size: 12, design: .monospaced))
                                        .onChange(of: app.draftPoll) { v in
                                            if let n = Int(v), n > 0 { app.settingsDraft?.refreshRateMs = n }
                                        }
                                    Text("ms").font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }

                            settingRow(label: "Flush Rate") {
                                HStack(spacing: 6) {
                                    TextField("300", text: $app.draftFlush)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 60)
                                        .font(.system(size: 12, design: .monospaced))
                                        .onChange(of: app.draftFlush) { v in
                                            if let n = Int(v), n > 0 { app.settingsDraft?.flushRateMs = n }
                                        }
                                    Text("ms").font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }

                            Text("Lower rates reduce latency but increase API calls.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(maxWidth: .infinity)

                    section("Appearance") {
                        VStack(alignment: .leading, spacing: 14) {
                            settingRow(label: "Theme") {
                                Picker("", selection: Binding(
                                    get: { app.settingsDraft?.theme ?? .system },
                                    set: { app.settingsDraft?.theme = $0 }
                                )) {
                                    Text("System").tag(AppTheme.system)
                                    Text("Light").tag(AppTheme.light)
                                    Text("Dark").tag(AppTheme.dark)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 150)
                                .labelsHidden()
                                .onChange(of: app.settingsDraft?.theme) { newTheme in
                                    if let t = newTheme {
                                        app.settings.theme = t
                                        app.saveSettings()
                                    }
                                }
                            }
                            
                            Text("The application theme adjusts immediately.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(maxWidth: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)

                // MARK: Save
                HStack {
                    if isRunning {
                        Label("Stop the tunnel before changing settings.", systemImage: "lock")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button(saved ? "Saved" : "Save") { saveDraft() }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.roundedRectangle)
                        .tint(saved ? .green : .accentColor)
                        .disabled(isRunning || !hasChanges)
                }
                .padding(.top, 4)

                // MARK: Reset
                Divider().opacity(0.15).padding(.vertical, 4)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reset Setup")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.red.opacity(0.85))
                        Text("Clears credentials and restarts the wizard.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reset…") { showResetConfirm = true }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.roundedRectangle)
                        .tint(.red)
                        .disabled(isRunning)
                }

                Spacer(minLength: 20)
            }
            .padding(32)
        }
        .onAppear { loadDraft() }
        .alert("Reset Setup?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) {
                Task { await app.resetWizard() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete your credentials and OAuth token, and return to the setup wizard. The tunnel will be stopped if running.")
        }
    }

    // MARK: - Helpers

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    content()
                }
            }
        }
    }

    private func settingRow<Control: View>(label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            control()
        }
    }

    private func modeButton(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selected ? Color.accentColor.opacity(0.2) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : .secondary)
    }

    private func loadDraft() {
        if app.settingsDraft == nil {
            app.settingsDraft = app.settings
            app.draftPort = "\(app.settings.listenPort)"
            app.draftPoll = "\(app.settings.refreshRateMs)"
            app.draftFlush = "\(app.settings.flushRateMs)"
        }
        lanIP = AppState.getLANIPAddress()
    }

    private func saveDraft() {
        guard let d = app.settingsDraft else { return }
        app.settings = d
        app.saveSettings()
        withAnimation { saved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { saved = false }
        }
    }
}
