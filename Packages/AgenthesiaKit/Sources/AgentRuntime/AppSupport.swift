public import Foundation

/// The app's folder in `Application Support`. A build with a suffixed bundle identifier (`….Agenthesia.dev`)
/// keeps its own data in `Agenthesia-dev`, so it never touches the installed app's history or installs.
public enum AppSupport {
    private static let bundleIdentifier = "io.github.anesthetised.Agenthesia"

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: folderName(bundleIdentifier: Bundle.main.bundleIdentifier))
    }

    /// `Agenthesia` for the original identifier, a missing one (tests, the CLI) and any unrelated one;
    /// `Agenthesia-<suffix>` for `io.github.anesthetised.Agenthesia.<suffix>`.
    static func folderName(bundleIdentifier identifier: String?) -> String {
        guard let identifier, identifier.hasPrefix(bundleIdentifier + ".") else { return "Agenthesia" }
        let suffix = identifier.dropFirst(bundleIdentifier.count + 1)
        return suffix.isEmpty ? "Agenthesia" : "Agenthesia-\(suffix)"
    }
}
