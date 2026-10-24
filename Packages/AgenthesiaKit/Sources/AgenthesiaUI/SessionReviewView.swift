import AgenthesiaCore
import SwiftUI

/// A native file list and the selected unified diff; the same file invalidations refresh both panes.
struct SessionReviewView: View {
    @Bindable var review: SessionReview
    let files: SessionFiles
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Review Changes").font(.headline)
                    if let branch = review.baseBranch {
                        Text("Changes against \(branch)").foregroundStyle(.secondary)
                    } else {
                        Text("Session changes").foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Refresh Files", systemImage: "arrow.clockwise") { Task { await files.refresh() } }
                    .labelStyle(.iconOnly)
            }.padding()
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
                HSplitView {
                    List(selection: $review.selectedPath) {
                        ForEach(review.changes) { change in
                            VStack(alignment: .leading) {
                                Text(change.path).lineLimit(2).truncationMode(.middle)
                                Text(change.status.rawValue).font(.caption).foregroundStyle(.secondary)
                                if let previous = change.previousPath {
                                    Text("From \(previous)").font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(2).truncationMode(.middle)
                                }
                            }
                            .tag(change.path)
                            .help(change.path)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .accessibilityLabel("Changed files")
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: 320, maxHeight: .infinity)
                    SessionReviewDetail(review: review)
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                if let error = files.watchError {
                    Text("Automatic refresh is unavailable: \(error)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
        }
        .frame(
            minWidth: 640,
            idealWidth: 900,
            maxWidth: .infinity,
            minHeight: 400,
            idealHeight: 600,
            maxHeight: .infinity
        )
        .task(id: files.indexRevision) { await review.refresh() }
    }
}
