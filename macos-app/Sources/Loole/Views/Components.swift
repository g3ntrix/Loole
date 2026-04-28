import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Card

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(20)
            .background(
                VisualEffectView(material: .sidebar, blendingMode: .withinWindow)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.primary.opacity(0.1), lineWidth: 0.5)
                    )
            )
            .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - StatusDot

struct StatusDot: View {
    let color: Color
    var animated: Bool = false
    @State private var pulsing = false

    var body: some View {
        ZStack {
            if animated {
                Circle().fill(color.opacity(0.25))
                    .frame(width: 20, height: 20)
                    .scaleEffect(pulsing ? 1.6 : 1.0)
                    .opacity(pulsing ? 0 : 0.6)
                    .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulsing)
            }
            Circle().fill(color).frame(width: 10, height: 10)
        }
        .onAppear { if animated { pulsing = true } }
    }
}

// MARK: - CopyButton

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation { copied = false }
            }
        } label: {
            Label(copied ? "Copied!" : "Copy",
                  systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(copied ? Color.green : Color.accentColor)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - CodeBlock

struct CodeBlock: View {
    let label: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: code)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))

            Divider().opacity(0.2)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Step indicator

struct StepIndicator: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i <= current ? Color.accentColor : Color.primary.opacity(0.1))
                    .frame(height: 4)
                    .animation(.easeInOut(duration: 0.25), value: current)
            }
        }
    }
}

// MARK: - Background

struct AppBackground: View {
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        ZStack {
            if colorScheme == .dark {
                Color(.sRGB, red: 0.04, green: 0.05, blue: 0.08, opacity: 1)
            } else {
                Color(.sRGB, red: 0.98, green: 0.98, blue: 0.99, opacity: 1)
            }
            
            // Subtle mesh-like glow
            Circle()
                .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.12 : 0.08))
                .frame(width: 400, height: 400)
                .blur(radius: 120)
                .offset(x: -200, y: -200)
            
            Circle()
                .fill(colorScheme == .dark ? Color.purple.opacity(0.1) : Color.blue.opacity(0.05))
                .frame(width: 350, height: 350)
                .blur(radius: 120)
                .offset(x: 250, y: 200)
        }
        .ignoresSafeArea()
    }
}

// MARK: - WindowAccessor (transparent titlebar)

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            if let w = v.window {
                w.titlebarAppearsTransparent = true
                w.titleVisibility = .hidden
                w.isMovableByWindowBackground = false
                w.styleMask.insert(.fullSizeContentView)
            }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - PrimaryButton

struct PrimaryButton: View {
    let title: String
    let icon: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle)
        .tint(.accentColor)
        .disabled(disabled)
    }
}
// MARK: - NativeDropZone

struct NativeDropZone: NSViewRepresentable {
    @Binding var isDragging: Bool
    var onURLs: ([URL]) -> Void
    var onTap: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let view = DropNSView()
        view.onURLs = onURLs
        view.onTap = onTap
        view.isDragging = $isDragging
        // Ensure the view is layer-backed and can receive events
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? DropNSView {
            view.onURLs = onURLs
            view.onTap = onTap
        }
    }

    class DropNSView: NSView {
        var onURLs: (([URL]) -> Void)?
        var onTap: (() -> Void)?
        var isDragging: Binding<Bool>?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            // Register for a wide range of types to ensure compatibility
            registerForDraggedTypes([
                .fileURL,
                .URL,
                NSPasteboard.PasteboardType(UTType.json.identifier),
                NSPasteboard.PasteboardType(UTType.fileURL.identifier),
                .string
            ])
        }

        required init?(coder: NSCoder) { nil }

        override func mouseDown(with event: NSEvent) {
            onTap?()
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            let pboard = sender.draggingPasteboard
            let canAccept = pboard.canReadObject(forClasses: [NSURL.self], options: nil) ||
                           pboard.types?.contains(.fileURL) == true ||
                           pboard.types?.contains(NSPasteboard.PasteboardType(UTType.fileURL.identifier)) == true
            
            if canAccept {
                DispatchQueue.main.async { self.isDragging?.wrappedValue = true }
                return .copy
            }
            return []
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            return .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            DispatchQueue.main.async { self.isDragging?.wrappedValue = false }
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            DispatchQueue.main.async { self.isDragging?.wrappedValue = false }
            let pboard = sender.draggingPasteboard
            
            // Try modern NSURL reading first with options
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            if let urls = pboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
                onURLs?(urls)
                return true
            }
            
            // Fallback for string paths
            if let path = pboard.string(forType: .fileURL), let url = URL(string: path) {
                onURLs?([url])
                return true
            }
            
            return false
        }
    }
}
