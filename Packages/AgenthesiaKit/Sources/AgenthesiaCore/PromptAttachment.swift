public import ACP
public import Foundation
import UniformTypeIdentifiers

extension ACP.ResourceLink {
    /// A prompt reference to a local file or directory (ADR-0018). A path in the user's checkout points to
    /// the same path in the session worktree when it exists there, so the agent reads the copy it works on.
    public static func file(_ url: URL, checkout: (checkout: URL, worktree: URL)? = nil) -> ACP.ResourceLink {
        var url = url.resolvingSymlinksInPath().standardizedFileURL
        if let checkout, let relative = relativePath(of: url, in: checkout.checkout) {
            let mapped = relative.isEmpty ? checkout.worktree : checkout.worktree.appending(path: relative)
            if FileManager.default.fileExists(atPath: mapped.path) { url = mapped }
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey])
        let isDirectory = values?.isDirectory == true
        return ACP.ResourceLink(
            uri: url.absoluteString,
            name: url.lastPathComponent,
            mimeType: isDirectory ? nil : values?.contentType?.preferredMIMEType,
            size: isDirectory ? nil : values?.fileSize
        )
    }

    private static func relativePath(of url: URL, in root: URL) -> String? {
        let path = url.path, root = root.path
        if path == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }
}
