import SwiftUI

/// A grey line above the composer card about the session's settings; not an error.
struct ComposerNote: View {
    let text: String

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}
