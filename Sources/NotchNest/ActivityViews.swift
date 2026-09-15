import SwiftUI

extension Color {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
}

/// Under the closed notch: what Claude Code wants to do, with Deny and Allow.
struct ClaudeAskRow: View {
    let request: ClaudeRequest
    let bridge: ClaudeBridge

    var body: some View {
        HStack(spacing: 6) {
            Text(request.summary)
                .font(.system(size: 10, weight: .medium, design: request.tool == "Bash" ? .monospaced : .default))
                .foregroundStyle(Color.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("\(request.project): \(request.summary)")
            ClaudeButton(title: "Deny", prominent: false) { bridge.answer(request.id, .deny) }
            ClaudeButton(title: "Allow", prominent: true) { bridge.answer(request.id, .allow) }
        }
    }
}

/// The same question inside the open notch, so opening it doesn't hide the request.
struct ClaudeAskBar: View {
    let request: ClaudeRequest
    let bridge: ClaudeBridge
    let waiting: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.claude)
            VStack(alignment: .leading, spacing: 0) {
                Text("Claude · \(request.project)" + (waiting > 1 ? " · \(waiting) waiting" : ""))
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Text(request.summary)
                    .font(.system(size: 10, weight: .medium, design: request.tool == "Bash" ? .monospaced : .default))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ClaudeButton(title: "Terminal", prominent: false) { bridge.answer(request.id, .terminal) }
                .help("Answer in Claude Code instead")
            ClaudeButton(title: "Deny", prominent: false) { bridge.answer(request.id, .deny) }
            ClaudeButton(title: "Allow", prominent: true) { bridge.answer(request.id, .allow) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(white: 0.16)))
        .overlay(Capsule().strokeBorder(Color.claude.opacity(0.5)))
    }
}

struct ClaudeButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .foregroundStyle(prominent ? Color.black : Color.white)
                .background(Capsule().fill(prominent ? Color.claude : Color.white.opacity(0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Under the closed notch after a download: its name (click to show it in Finder) and "Add to Tray".
struct DownloadRow: View {
    let notice: DownloadNotice
    let vm: NotchViewModel

    var body: some View {
        HStack(spacing: 6) {
            Text(notice.url.lastPathComponent)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { vm.revealDownload() }
                .help("Show in Finder")
            if notice.inTray {
                Label("In Tray", systemImage: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.green)
                    .fixedSize()
            } else {
                Button { vm.addDownloadToTray() } label: {
                    Text("Add to Tray")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.16)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A file's Finder icon, for the download notice.
struct FileIcon: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: size, height: size)
    }
}
