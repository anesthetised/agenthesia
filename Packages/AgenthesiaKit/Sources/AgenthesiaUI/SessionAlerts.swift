import SwiftUI

/// The window's confirmations, Discard Worktree… and Delete Session…, and its failure alert.
struct SessionAlerts: ViewModifier {
    @Bindable var model: SessionWindowModel

    func body(content: Content) -> some View {
        content
            .alert(
                model.pendingDiscard?.title ?? "",
                isPresented: $model.isConfirmingDiscard,
                presenting: model.pendingDiscard
            ) { pending in
                Button("Discard", role: .destructive) { Task { await model.confirmDiscard(pending) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text($0.message)
            }
            .alert(
                model.pendingDelete?.title ?? "",
                isPresented: $model.isConfirmingDelete,
                presenting: model.pendingDelete
            ) { pending in
                Button("Delete", role: .destructive) { Task { await model.confirmDelete(pending) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text($0.message)
            }
            .alert(model.alertTitle, isPresented: $model.isShowingAlert, presenting: model.alertMessage) { _ in
            } message: {
                Text($0)
            }
    }
}
