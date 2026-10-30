import AppKit
import SwiftUI

/// The leading edge of a pane in the detail column: a hairline with a wider grab area, inside the pane, that
/// resizes the pane by dragging. It takes no room of its own; `RootView` lays the panes out with explicit widths.
struct PaneDivider: View {
    /// The pane's width now.
    let width: CGFloat
    /// Asks for a new width; the owner clamps it.
    let onResize: (CGFloat) -> Void
    @State private var startWidth: CGFloat?

    var body: some View {
        Rectangle().fill(.separator).frame(width: 1)
            .frame(width: 9, alignment: .leading).contentShape(.rect)
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = startWidth ?? width
                        startWidth = start
                        onResize(start - drag.translation.width)
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .accessibilityElement()
            .accessibilityLabel("Resize pane")
            .accessibilityValue(Text("\(Int(width)) points"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onResize(width + 20)
                case .decrement: onResize(width - 20)
                @unknown default: break
                }
            }
    }
}
