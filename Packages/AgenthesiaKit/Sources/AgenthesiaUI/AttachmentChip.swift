import AppKit
import SwiftUI

/// An attachment's file icon and name, with an action to remove it from the draft.
struct AttachmentChip: View {
    let url: URL
    let onRemove: () -> Void
    @State private var icon: NSImage?

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if let icon { Image(nsImage: icon).resizable() }
            }
            .frame(width: 16, height: 16).accessibilityHidden(true)
            Text(url.lastPathComponent).lineLimit(1)
            Button("Remove \(url.lastPathComponent)", systemImage: "xmark.circle.fill", action: onRemove)
                .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.quaternary, in: .capsule).help(url.path)
        .task(id: url) { icon = NSWorkspace.shared.icon(forFile: url.path) }
    }
}
