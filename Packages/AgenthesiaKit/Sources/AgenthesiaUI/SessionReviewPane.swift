import AgenthesiaCore
import SwiftUI

/// The review in the file pane's slot (ADR-0041): what is compared, a native file list and the selected file's
/// diff. The same file invalidations refresh the list and the diff.
struct SessionReviewPane: View {
    @Bindable var review: SessionReview
    let files: SessionFiles
    let model: SessionWindowModel
    /// The pane's height; the file list takes at most a third of it.
    let height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(review.baseBranch.map { "Changes against \($0)" } ?? "Session changes").font(.headline)
                    .lineLimit(1).truncationMode(.middle)
                WatchErrorNotice(files: files)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            Divider()
            if let error = review.error {
                ContentUnavailableView {
                    Label("Cannot Review Changes", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error).textSelection(.enabled)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if review.isLoading {
                ProgressView("Checking changes…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if review.changes.isEmpty {
                ContentUnavailableView("No changes", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fileList
                Divider()
                SessionReviewDetail(review: review, onEscape: close)
            }
            Divider()
            // Ask agent (#215) goes before Merge, the viewed count (#214) after it.
            HStack {
                Button("Merge…") { Task { await model.requestMerge() } }
                    .disabled(!model.canMerge)
                    .help(model.mergeHelp ?? "")
                Spacer()
            }.padding(8)
        }
        .onExitCommand(perform: close)
        .task(id: files.indexRevision) { await review.refresh() }
    }

    private var fileList: some View {
        List(selection: $review.selectedPath) {
            ForEach(review.changes) { change in
                VStack(alignment: .leading) {
                    Text(change.path).lineLimit(1).truncationMode(.middle)
                    Text(change.status.rawValue).font(.caption).foregroundStyle(.secondary)
                    if let previous = change.previousPath {
                        Text("From \(previous)").font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .tag(change.path)
                .help(change.path)
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityLabel("Changed files")
        // ponytail: estimated row heights; a list of renames is cut a little early, measure rows if that matters.
        .frame(height: min(CGFloat(review.changes.count) * 36 + 12, height / 3))
    }

    private func close() { model.showingReview = false }
}
