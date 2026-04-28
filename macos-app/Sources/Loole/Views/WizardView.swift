import SwiftUI
import UniformTypeIdentifiers

/// The client-side setup wizard: credentials → OAuth → server packaging.
struct WizardView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var auth = GoogleAuth()
    @State private var step: Int = 0        // 0=credentials, 1=authorize, 2=server
    @State private var credError: String?
    @State private var isDraggingOver = false
    @State private var credentialsImported = false

    @Environment(\.controlActiveState) var activeState
    private let store = ConfigStore()

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(spacing: 28) {
                    header
                    StepIndicator(current: step, total: 3)
                        .padding(.horizontal, 4)

                    VStack(spacing: 0) {
                        contentForStep(step)
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal:   .move(edge: .leading).combined(with: .opacity)
                    ))
                    .animation(.easeInOut(duration: 0.3), value: step)
                }
                .padding(32)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            credentialsImported = store.credentialsExist()
        }
    }

    @ViewBuilder
    private func contentForStep(_ s: Int) -> some View {
        switch s {
        case 0: credentialsStep
        case 1: authorizeStep
        case 2: ServerWizardView(onComplete: {
            app.completeWizard()
        }, onBack: {
            withAnimation { step = 1 }
        })
        default: EmptyView()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
                HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .cornerRadius(12)
                Text("Setup Loole")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer()
            }
            Text("Let's get your private tunnel running in three steps.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Step 0: Credentials

    private var credentialsStep: some View {
        Card {
            VStack(alignment: .leading, spacing: 18) {
                stepTitle(number: 1, title: "Get your Google credentials")

                Text("Follow these 4 quick steps. Each one has a direct link so you never have to hunt through Google's menus.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 12) {
                    credStep(
                        letter: "A",
                        title: "Enable the Google Drive API",
                        detail: "Click the link below. Create a new project (name it whatever you like, e.g. \"Loole\") if prompted, then press **ENABLE**.",
                        linkLabel: "Enable Drive API →",
                        url: "https://console.cloud.google.com/flows/enableapi?apiid=drive.googleapis.com"
                    )
                    Divider().opacity(0.15)
                    credStep(
                        letter: "B",
                        title: "Set up app branding",
                        detail: "Click **GET STARTED**, fill in any app name and your email, set audience to **External**, then click through the remaining screens and finally click **CREATE**.",
                        linkLabel: "Open Branding page →",
                        url: "https://console.cloud.google.com/auth/branding"
                    )
                    Divider().opacity(0.15)
                    credStep(
                        letter: "C",
                        title: "Publish your app",
                        detail: "Click **PUBLISH APP** and confirm. This prevents your token from expiring every 7 days.",
                        linkLabel: "Open Publish page →",
                        url: "https://console.cloud.google.com/auth/audience"
                    )
                    Divider().opacity(0.15)
                    credStep(
                        letter: "D",
                        title: "Create OAuth credentials",
                        detail: "Click **+ CREATE CLIENT**, choose **Desktop app**, name it anything (e.g. \"MyVPN\"), click **CREATE**. Then click **DOWNLOAD JSON** in the popup.",
                        linkLabel: "Create OAuth Client →",
                        url: "https://console.cloud.google.com/apis/credentials/oauthclient"
                    )
                }

                Divider().opacity(0.2)

                // Drop zone
                Text("Your credentials.json file:")
                    .font(.system(size: 12, weight: .medium))

                dropZone

                if let err = credError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .padding(.top, -8)
                }

                if credentialsImported {
                    HStack {
                        Spacer()
                        Button("Next: Authorize") {
                            withAnimation { step = 1 }
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.roundedRectangle)
                        .tint(.accentColor)
                        .controlSize(.large)
                        .background(
                             RoundedRectangle(cornerRadius: 7, style: .continuous)
                                 .fill(activeState == .inactive ? Color.gray.opacity(0.4) : Color.accentColor)
                        )
                    }
                    .padding(.top, 8)
                }
            }
        }
    }

    private func credStep(letter: String, title: String, detail: String, linkLabel: String, url: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 24, height: 24)
                Text(letter)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(.init(detail))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let linkURL = URL(string: url) {
                    Link(destination: linkURL) {
                        HStack(spacing: 4) {
                            Text(linkLabel)
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }

    private var dropZone: some View {
        ZStack {
            // Visual layer (now at the bottom so it's always visible)
            Group {
                if credentialsImported {
                    importedStateView
                } else {
                    emptyStateView
                }
            }
            .animation(.spring(response: 0.3), value: credentialsImported)

            // Native handler on top, only active when not imported
            if !credentialsImported {
                NativeDropZone(isDragging: $isDraggingOver, onURLs: { urls in
                    if let url = urls.first { importCredentials(from: url) }
                }, onTap: {
                    browseForCredentials()
                })
                .background(Color.white.opacity(0.001)) // Ensure it's hittable
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 90)
        .animation(.easeInOut(duration: 0.2), value: isDraggingOver)
    }

    private var importedStateView: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.green)
            }
            
            VStack(alignment: .leading, spacing: 3) {
                Text("Credentials Ready")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)
                Text("oauth_credentials.json successfully verified")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button {
                deleteCredentials()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                    Text("Replace")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.green.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.green.opacity(0.15), lineWidth: 1)
                )
        )
    }

    private var emptyStateView: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 22))
                .foregroundStyle(isDraggingOver ? Color.accentColor : Color.secondary)
            Text("Drop your OAuth JSON here")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("or click to browse")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isDraggingOver ? Color.accentColor : Color.primary.opacity(0.1),
                    style: StrokeStyle(lineWidth: 2, dash: [6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isDraggingOver ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
                )
        )
    }

    private func browseForCredentials() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Select your credentials.json from Google Cloud Console"
        if panel.runModal() == .OK, let url = panel.url {
            importCredentials(from: url)
        }
    }


    private func deleteCredentials() {
        withAnimation {
            try? store.deleteCredentials()
            credentialsImported = false
            credError = nil
        }
    }

    private func importCredentials(from url: URL) {
        let _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }

        credError = nil
        // Validate it looks like a Google OAuth file
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["installed"] != nil || json["web"] != nil) else {
            DispatchQueue.main.async {
                self.credError = "This doesn't look like a valid Google OAuth credentials file."
                self.credentialsImported = false
            }
            return
        }
        do {
            try store.importCredentials(from: url)
            DispatchQueue.main.async {
                withAnimation {
                    self.credentialsImported = true
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.credError = error.localizedDescription
                self.credentialsImported = false
            }
        }
    }

    // MARK: - Step 1: Authorize

    private var authorizeStep: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                stepTitle(number: 2, title: "Connect your Google account")

                Text("Loole needs permission to create files in your Google Drive. This is the encrypted tunnel channel. Click **Authorize** and sign in. The browser will redirect back automatically; no copy-pasting needed.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                authStatusView

                // Troubleshooting tips (always visible — common gotchas)
                VStack(alignment: .leading, spacing: 8) {
                    Text("If something goes wrong:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    tipRow(
                        icon: "exclamationmark.shield",
                        text: "**\"Access blocked\"**: your app is still in Testing mode.",
                        linkLabel: "Click here to Publish App",
                        url: "https://console.cloud.google.com/auth/audience"
                    )
                    tipRow(
                        icon: "exclamationmark.triangle",
                        text: "**\"App not verified\"**: click **Advanced**, then **Go to app (unsafe)**. This is expected for personal apps.",
                        linkLabel: nil, url: nil
                    )
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.15), lineWidth: 1))

                HStack {
                    if step > 0 {
                        Button("← Back") {
                            auth.reset()
                            withAnimation { step = 0 }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()

                    switch auth.phase {
                    case .idle, .failed:
                        Button("Authorize with Google") {
                            auth.startAuthorize(credentialsURL: store.credentialsURL)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.roundedRectangle)
                        .tint(.accentColor)
                        .controlSize(.large)
                        .background(
                             RoundedRectangle(cornerRadius: 7, style: .continuous)
                                 .fill(activeState == .inactive ? Color.gray.opacity(0.4) : Color.accentColor)
                        )

                    case .waitingForBrowser, .exchanging, .findingFolder:
                        ProgressView().controlSize(.small)
                        Text(auth.phase == .waitingForBrowser
                             ? "Waiting for browser…"
                             : auth.phase == .exchanging
                             ? "Verifying tokens…"
                             : "Setting up Drive folder…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Button("Cancel") { auth.reset() }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)

                    case .done(let folderID):
                        Button("Next: Server Setup") {
                            app.settings.folderID = folderID
                            app.saveSettings()
                            withAnimation { step = 2 }
                        }
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
    }

    private var authStatusView: some View {
        VStack(alignment: .leading, spacing: 10) {
            authRow(
                done: !auth.accessToken.isEmpty || auth.phase == .done(folderID: ""),
                active: auth.phase == .waitingForBrowser || auth.phase == .exchanging,
                label: "Google account authorized"
            )
            authRow(
                done: {
                    if case .done = auth.phase { return true }
                    return false
                }(),
                active: auth.phase == .findingFolder,
                label: "\"Flow-Data\" folder ready in Drive"
            )
        }
    }

    private func authRow(done: Bool, active: Bool, label: String) -> some View {
        HStack(spacing: 10) {
            if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if active {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "circle").foregroundStyle(.secondary.opacity(0.4))
            }
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(done ? .primary : .secondary)
        }
    }

    // MARK: - Helpers

    private func stepTitle(number: Int, title: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.2)).frame(width: 28, height: 28)
                Text("\(number)").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Color.accentColor)
            }
            Text(title).font(.system(size: 16, weight: .semibold))
        }
    }

    private func tipRow(icon: String, text: String, linkLabel: String?, url: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(Color.orange)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(.init(text)).font(.system(size: 11)).foregroundStyle(.secondary)
                if let label = linkLabel, let urlStr = url, let linkURL = URL(string: urlStr) {
                    Link(destination: linkURL) {
                        HStack(spacing: 3) {
                            Text(label)
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }
}
