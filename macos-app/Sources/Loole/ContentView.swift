import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        mainUI
            .background(WindowAccessor())
            .environmentObject(app)
    }

    private var mainUI: some View {
        Group {
            if app.isWizardComplete {
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
                } detail: {
                    ZStack {
                        AppBackground()
                        Group {
                            switch app.activeTab {
                            case .dashboard: DashboardView()
                            case .logs:      LogsView()
                            case .server:    ServerWizardView(onComplete: nil, onBack: nil)
                            case .setup:     WizardView()
                            case .settings:  SettingsView()
                            case .about:     AboutView()
                            }
                        }
                        .navigationTitle(app.activeTab.title)
                    }
                }
            } else {
                ZStack {
                    AppBackground()
                    WizardView()
                }
                .navigationTitle("Setup Loole")
            }
        }
    }

    private var sidebar: some View {
        sidebarContent
    }

    @Environment(\.colorScheme) var colorScheme

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            // App identity
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26, height: 26)
                Text("Loole")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 52)
            .padding(.bottom, 20)

            // Status pill
            HStack(spacing: 6) {
                StatusDot(color: statusColor, animated: app.status.isRunning)
                Text(app.status.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().opacity(0.2)
                .padding(.bottom, 8)

            // Primary nav
            ForEach([AppState.Tab.dashboard, .logs, .server, .setup]) { t in
                sidebarItem(t)
            }

            Spacer()

            Divider().opacity(0.2)
                .padding(.bottom, 8)
                .padding(.top, 4)

            // Secondary nav
            ForEach([AppState.Tab.settings, .about]) { t in
                sidebarItem(t)
            }
            .padding(.bottom, 12)
        }
        .background(colorScheme == .dark ? Color(.sRGB, red: 0.05, green: 0.06, blue: 0.10, opacity: 1) : Color(.sRGB, red: 0.94, green: 0.95, blue: 0.97, opacity: 1))
    }

    private func sidebarItem(_ t: AppState.Tab) -> some View {
        Button {
            app.activeTab = t
        } label: {
            HStack(spacing: 10) {
                Image(systemName: t.symbol)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(t.title)
                    .font(.system(size: 13, weight: app.activeTab == t ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(app.activeTab == t ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(app.activeTab == t ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 8)
    }

    private var statusColor: Color {
        switch app.status {
        case .running:              return .green
        case .starting, .stopping:  return .yellow
        case .error:                return .orange
        case .stopped:              return .secondary.opacity(0.4)
        }
    }
}
