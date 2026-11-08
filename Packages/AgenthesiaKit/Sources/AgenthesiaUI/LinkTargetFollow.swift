import AgenthesiaCore
import AppKit

extension LinkTarget {
    /// Does what the link asks: a file opens through `openFile`, a web or mail link in the system's app.
    func follow(openFile: (String) -> Void) {
        switch self {
        case .file(let path): openFile(path)
        case .external(let url): NSWorkspace.shared.open(url)
        case .ignored: break
        }
    }
}
