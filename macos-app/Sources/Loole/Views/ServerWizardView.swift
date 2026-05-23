import SwiftUI

struct ServerWizardView: View {
    var onComplete: (() -> Void)?
    var onBack: (() -> Void)?

    @EnvironmentObject var app: AppState
    @State private var mode: ServerPackager.Mode = .firstTimeServer
    @State private var detectedArch: String?
    @State private var serverIP: String = ""
    @State private var serverPassword: String = ""
    @State private var includeSSH = false
    @State private var zipURL: URL?
    @State private var instructionsURL: URL?
    @State private var exportInstructions = true
    @State private var isBuilding = false
    @State private var buildError: String?

    @Environment(\.controlActiveState) var activeState
    private let store = ConfigStore()

    var body: some View {
        if isEmbeddedInSetupWizard {
            content
        } else {
            ScrollView {
                content
                    .padding(.vertical, 24)
            }
        }
    }

    private var isEmbeddedInSetupWizard: Bool {
        onBack != nil || onComplete != nil
    }

    private var content: some View {
        VStack {
            Card {
                VStack(alignment: .leading, spacing: zipURL == nil ? 24 : 14) {
                    stepHeader

                    if zipURL == nil {
                        modePicker
                        Divider().opacity(0.15)
                        if mode == .firstTimeServer {
                            archDetectionSection
                        } else {
                            addDeviceSection
                        }
                    } else {
                        deploySection
                    }
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Header

    private var stepHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 32, height: 32)
                Text("3").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Set Up Your Server").font(.system(size: 18, weight: .bold))
                Text("The server is what routes your internet traffic.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which situation applies to you?")
                .font(.system(size: 13, weight: .semibold))

            modeCard(
                selected: mode == .firstTimeServer,
                icon: "server.rack",
                title: "I need to set up a new server",
                subtitle: "You'll get a package to install on your VPS."
            ) {
                mode = .firstTimeServer
                detectedArch = nil
            }

            modeCard(
                selected: mode == .addClient,
                icon: "plus.rectangle.on.rectangle",
                title: "A server is already running — add this Mac to it",
                subtitle: "You'll get a small file to send to whoever manages the server."
            ) {
                mode = .addClient
            }
        }
    }

    private func modeCard(selected: Bool, icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(selected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - First-time setup

    private var archDetectionSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What type of server do you have?")
                    .font(.system(size: 13, weight: .semibold))
                Text("Check with your hosting provider if you're not sure. Most servers use Standard.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                archButton(arch: "amd64", label: "Standard", subtitle: "Most common\n(Hetzner, DigitalOcean, Linode…)")
                archButton(arch: "arm64", label: "ARM", subtitle: "Less common\n(Oracle Free Tier, Ampere…)")
            }

            instructionsToggle
            errorAndActions(buildEnabled: detectedArch != nil, buildLabel: "Create Server Package")
        }
    }

    // MARK: - Add device

    private var addDeviceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("This will create a small file for this Mac.")
                    .font(.system(size: 13, weight: .semibold))
                Text("Send it to whoever manages your server along with the steps that appear after. They just need to run a few commands — no restart required.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            instructionsToggle
            errorAndActions(buildEnabled: true, buildLabel: "Create Device File")
        }
    }

    // MARK: - Shared sub-views

    private var instructionsToggle: some View {
        Toggle(isOn: $exportInstructions) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Also save a setup guide")
                    .font(.system(size: 12, weight: .medium))
                Text("A plain-text file with the exact steps, saved next to your package.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 2)
    }

    private func errorAndActions(buildEnabled: Bool, buildLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let err = buildError {
                Label(err, systemImage: "xmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack {
                if let back = onBack {
                    Button("← Go Back") { back() }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Spacer()
                if isBuilding {
                    ProgressView().controlSize(.small)
                    Text("Building…").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Button(buildLabel) { buildPackage() }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.roundedRectangle)
                        .tint(.accentColor)
                        .controlSize(.large)
                        .background(
                             RoundedRectangle(cornerRadius: 7, style: .continuous)
                                 .fill(activeState == .inactive ? Color.gray.opacity(0.4) : Color.accentColor)
                        )
                        .disabled(!buildEnabled)
                }
            }
        }
    }

    private func archButton(arch: String, label: String, subtitle: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { detectedArch = arch }
        } label: {
            VStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 15, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(detectedArch == arch ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(detectedArch == arch ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: 1.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(detectedArch == arch ? Color.accentColor : Color.primary)
    }

    // MARK: - Deploy section

    private var deploySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(mode == .firstTimeServer ? "Your server package is ready!" : "Your device file is ready!",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.green)
                Spacer()
                Button("Show in Finder") {
                    if let url = zipURL { ServerPackager.revealInFinder(url) }
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.accentColor)
            }

            Text(mode == .firstTimeServer
                 ? "Run these in order. Install & Restart also stops any previous Loole server first."
                 : "Run these in order on the existing server.")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            // SSH options
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Include upload commands", isOn: $includeSSH)
                        .toggleStyle(.switch)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                }

                if includeSSH {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "network").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 14)
                            Text("Server IP:").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                            TextField("e.g. 85.34.12.99", text: $serverIP)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        }
                        if !serverIP.isEmpty && !serverIPValid {
                            Text("Enter a valid IPv4 address")
                                .font(.system(size: 10)).foregroundStyle(.red).padding(.leading, 100)
                        }
                        HStack(spacing: 10) {
                            Image(systemName: "lock").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 14)
                            Text("Password:").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                            SecureField("Optional", text: $serverPassword)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)

            if let url = zipURL {
                let steps = ServerPackager.deploymentCommands(
                    mode: mode,
                    zipURL: url,
                    clientID: app.settings.clientID,
                    serverIP: serverIP,
                    includeSSH: includeSSH,
                    serverPassword: serverPassword
                )

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Commands")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        CopyButton(text: steps.map { $0.code }.joined(separator: "\n"))
                    }

                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                                CompactCommandRow(number: index + 1, label: step.label, code: step.code)
                            }
                        }
                        .padding(1)
                    }
                    .frame(maxHeight: mode == .firstTimeServer ? 230 : 190)
                }
                .padding(10)
                .background(Color.primary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }

            Divider().opacity(0.15)

            HStack {
                Button("← Start Over") {
                    zipURL = nil
                    buildError = nil
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)

                Spacer()

                if onComplete != nil {
                    Button("All Done") { onComplete?() }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.roundedRectangle)
                        .tint(.accentColor)
                        .controlSize(.large)
                        .background(
                             RoundedRectangle(cornerRadius: 7, style: .continuous)
                                 .fill(activeState == .inactive ? Color.gray.opacity(0.4) : Color.accentColor)
                        )
                }
            }
        }
    }

    // MARK: - Validation

    private var serverIPValid: Bool {
        let parts = serverIP.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { guard let n = Int($0) else { return false }; return (0...255).contains(n) }
    }

    // MARK: - Build

    private func buildPackage() {
        if mode == .firstTimeServer && detectedArch == nil { return }
        isBuilding = true
        buildError = nil

        Task {
            do {
                let result = try ServerPackager.buildPackage(
                    mode: mode,
                    arch: detectedArch,
                    exportInstructions: exportInstructions,
                    settings: app.settings,
                    store: store
                )
                await MainActor.run {
                    zipURL = result.zipURL
                    instructionsURL = result.instructionsURL
                    isBuilding = false
                    ServerPackager.revealInFinder(result.zipURL)
                }
            } catch {
                await MainActor.run {
                    buildError = error.localizedDescription
                    isBuilding = false
                }
            }
        }
    }
}

private struct CompactCommandRow: View {
    let number: Int
    let label: String
    let code: String

    var body: some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(label.hasPrefix("Optional") ? .secondary : .primary)

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            CopyButton(text: code)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
