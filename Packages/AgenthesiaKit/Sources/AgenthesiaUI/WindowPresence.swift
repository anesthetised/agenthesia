import AppKit
import Observation

/// Whether a window is open, for the item that opens one when none is. The app keeps running after its last window
/// closes (ADR-0026), and AppKit tells nothing a menu could observe, so the notifications do.
@MainActor @Observable final class WindowPresence {
    private(set) var isOpen: Bool
    @ObservationIgnored private let count: () -> Int
    @ObservationIgnored private var tokens: [any NSObjectProtocol] = []

    init(count: @escaping () -> Int = { NSApp?.windows.count { $0.isVisible && $0.canBecomeMain } ?? 0 }) {
        self.count = count
        isOpen = count() > 0
        let names: [Notification.Name] = [
            NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
        ]
        // A closing window is still visible when it announces it, so count once it has gone.
        tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    isolated deinit { tokens.forEach(NotificationCenter.default.removeObserver) }

    func refresh() { isOpen = count() > 0 }
}
