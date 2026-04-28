import SwiftUI

struct LogsView: View {
    @EnvironmentObject var app: AppState
    @State private var autoScroll = true
    @State private var showCopiedFeedback = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider().opacity(0.2)
            logList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var toolbar: some View {
        HStack {
            Text("Logs")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button {
                let allLogs = app.logs.map { "[\($0.timestamp.formatted())] \($0.text)" }.joined()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(allLogs, forType: .string)
                
                withAnimation { showCopiedFeedback = true }
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run { withAnimation { showCopiedFeedback = false } }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                    Text(showCopiedFeedback ? "Copied!" : "Copy")
                }
                .font(.system(size: 11))
                .foregroundStyle(showCopiedFeedback ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(app.logs.isEmpty)

            Button {
                app.clearLogs()
            } label: {
                Label("Clear", systemImage: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(app.logs) { line in
                        logRow(line)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: app.logs.count) { _ in
                if autoScroll, let last = app.logs.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func logRow(_ line: LogLine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(line.timestamp.formatted(date: .omitted, time: .standard))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.6))
                .frame(width: 68, alignment: .leading)

            Text(line.text.trimmingCharacters(in: .newlines))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(lineColor(line))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }

    private func lineColor(_ line: LogLine) -> Color {
        switch line.stream {
        case .system: return Color.accentColor.opacity(0.8)
        case .stderr: return Color.orange
        case .stdout: return Color.primary.opacity(0.8)
        }
    }
}
