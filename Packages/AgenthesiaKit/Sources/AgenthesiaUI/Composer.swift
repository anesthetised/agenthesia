import ACP
import AgenthesiaCore
import AppKit
import SwiftUI

/// The prompt editor: attached files, the agent's slash commands and a multi-line text view.
struct ComposerInput: View {
    @Binding var text: String
    @Binding var attachments: [URL]
    let commands: [ACP.AvailableCommand]
    let isEnabled: Bool
    let onSubmit: (SessionController.SubmissionIntent) -> Void
    var attachmentsEditable = true
    var onRecall: () -> Void = {}
    var onStop: () -> Void = {}
    @State private var selection = 0
    /// Escape hides the commands until the draft leaves command mode.
    @State private var dismissed = false

    var body: some View {
        let matches = dismissed ? [] : Self.commandMatches(text, in: commands)
        VStack(alignment: .leading, spacing: 8) {
            if !matches.isEmpty { commandList(matches).disabled(!isEnabled) }
            if !attachments.isEmpty { chips.disabled(!attachmentsEditable || !isEnabled) }
            ComposerTextView(
                text: $text,
                isEditable: isEnabled,
                onCommand: { handle($0, matches: matches) },
                onFiles: { if isEnabled && attachmentsEditable { Self.add($0, to: &attachments) } },
                onShortcut: { handleShortcut($0, matches: matches) }
            )
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Message the agent…").foregroundStyle(Color(nsColor: .placeholderTextColor))
                        .padding(.leading, ComposerTextView.padding).allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .onChange(of: text) {
            if Self.commandMatches(text, in: commands).isEmpty { dismissed = false }
            selection = 0
        }
    }

    private func commandList(_ matches: [ACP.AvailableCommand]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches.enumerated(), id: \.element.name) { index, command in
                        Button {
                            complete(command)
                        } label: {
                            HStack(spacing: 8) {
                                Text(verbatim: "/\(command.name)").font(.body.monospaced())
                                Text(command.description).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 0)
                                if let hint = command.input?.hint {
                                    Text(hint).foregroundStyle(.tertiary).lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4).contentShape(.rect)
                            .background(
                                index == selection ? AnyShapeStyle(.tint.quaternary) : AnyShapeStyle(.clear),
                                in: .rect(cornerRadius: 6)
                            )
                        }
                        .buttonStyle(.plain).id(command.name)
                        .accessibilityAddTraits(index == selection ? .isSelected : [])
                    }
                }
            }
            .frame(maxHeight: 180).fixedSize(horizontal: false, vertical: true)
            .onChange(of: selection) {
                if matches.indices.contains(selection) { proxy.scrollTo(matches[selection].name) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands")
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(attachments, id: \.self) { url in
                    AttachmentChip(url: url) {
                        attachments.removeAll { $0 == url }
                    }
                }
            }
        }
        .scrollIndicators(.never)
    }

    private func handleShortcut(_ event: NSEvent, matches: [ACP.AvailableCommand]) -> Bool {
        guard isEnabled, event.modifierFlags.contains(.command) else { return false }
        // Return and keypad Enter must reach the composer while NSTextView is first responder.
        if event.keyCode == 36 || event.keyCode == 76 {
            return handle(#selector(NSResponder.insertNewline(_:)), matches: matches, modifiers: event.modifierFlags)
        }
        if event.charactersIgnoringModifiers == "." {
            return handle(#selector(NSResponder.cancelOperation(_:)), matches: matches, modifiers: event.modifierFlags)
        }
        return false
    }

    private func handle(
        _ selector: Selector,
        matches: [ACP.AvailableCommand],
        modifiers: NSEvent.ModifierFlags? = nil
    ) -> Bool {
        let modifiers = modifiers ?? NSApp.currentEvent?.modifierFlags ?? []
        let lineBreak = !modifiers.intersection([.shift, .option]).isEmpty
        guard
            let action = Self.keyAction(
                selector,
                matches: matches.count,
                selection: selection,
                lineBreak: lineBreak,
                command: modifiers.contains(.command),
                shift: modifiers.contains(.shift),
                empty: text.isEmpty && attachments.isEmpty
            )
        else { return false }
        switch action {
        case .select(let index): selection = index
        case .complete(let index): complete(matches[index])
        case .dismiss: dismissed = dismissed || !matches.isEmpty
        case .submit: onSubmit(.whenReady)
        case .sendNow: onSubmit(.now)
        case .sendAllNow: onSubmit(.allNow)
        case .recall: onRecall()
        case .stop: onStop()
        }
        return true
    }

    enum KeyAction: Equatable { case select(Int), complete(Int), dismiss, submit, sendNow, sendAllNow, recall, stop }

    /// What a key command does with `matches` commands listed; nil leaves it to the text view.
    static func keyAction(
        _ selector: Selector,
        matches: Int,
        selection: Int,
        lineBreak: Bool,
        command: Bool = false,
        shift: Bool = false,
        empty: Bool = false
    ) -> KeyAction? {
        if command {
            if selector == #selector(NSResponder.insertNewline(_:)) { return shift ? .sendAllNow : .sendNow }
            if selector == #selector(NSResponder.cancelOperation(_:)) { return .stop }
        }
        if selector == #selector(NSResponder.insertNewline(_:)), lineBreak { return nil }
        if empty, selector == #selector(NSResponder.moveUp(_:)) { return .recall }
        if matches > 0 {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): return .select(max(selection - 1, 0))
            case #selector(NSResponder.moveDown(_:)): return .select(min(selection + 1, matches - 1))
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)):
                return .complete(min(selection, matches - 1))
            default: break
            }
        }
        switch selector {
        // Always consumed: NSTextView would otherwise open word completion.
        case #selector(NSResponder.cancelOperation(_:)): return .dismiss
        // ⇧Return and ⌥Return insert a line break.
        case #selector(NSResponder.insertNewline(_:)): return lineBreak ? nil : .submit
        default: return nil
        }
    }

    private func complete(_ command: ACP.AvailableCommand) {
        text = "/\(command.name) "
    }

    /// Commands whose name starts with the draft while it is a bare `/word`.
    static func commandMatches(_ draft: String, in commands: [ACP.AvailableCommand]) -> [ACP.AvailableCommand] {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return [] }
        let query = draft.dropFirst().lowercased()
        return commands.filter { $0.name.lowercased().hasPrefix(query) }
    }

    static func add(_ urls: [URL], to attachments: inout [URL]) {
        for url in urls where url.isFileURL && !attachments.contains(url) { attachments.append(url) }
    }
}

/// A plain-text `NSTextView` that grows with its content and hands file drops and pastes to `onFiles`.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    /// Return true to consume a key command such as `insertNewline:`.
    var onCommand: (Selector) -> Bool
    var onFiles: ([URL]) -> Void
    var onShortcut: (NSEvent) -> Bool = { _ in false }

    static let font = NSFont.preferredFont(forTextStyle: .body)
    private static let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
    static let lines = 2...6
    static let padding: CGFloat = 5

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = FileTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = Self.padding
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Message")
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        update(textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? FileTextView else { return }
        update(textView, coordinator: context.coordinator)
    }

    private func update(_ textView: FileTextView, coordinator: Coordinator) {
        coordinator.parent = self
        textView.onFiles = onFiles
        textView.onShortcut = onShortcut
        textView.isEditable = isEditable
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        return CGSize(width: width, height: Self.height(of: text, width: width))
    }

    /// The content height for the width, clamped to `lines`.
    static func height(of text: String, width: CGFloat) -> CGFloat {
        let line = lineHeight
        var content = (text as NSString).boundingRect(
            with: CGSize(width: max(width - 2 * padding, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height
        // A trailing line break starts an empty line that the bounding rectangle omits.
        if text.hasSuffix("\n") { content += line }
        return ceil(min(max(content, line * CGFloat(lines.lowerBound)), line * CGFloat(lines.upperBound)))
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            parent.onCommand(selector)
        }
    }
}

/// Turns pasted and dropped files into attachments instead of inserting their paths.
final class FileTextView: NSTextView {
    var onFiles: ([URL]) -> Void = { _ in }
    var onShortcut: (NSEvent) -> Bool = { _ in false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onShortcut(event) || super.performKeyEquivalent(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func paste(_ sender: Any?) {
        if !takeFiles(from: .general) { super.paste(sender) }
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        takeFiles(from: sender.draggingPasteboard) || super.performDragOperation(sender)
    }

    /// Passes the pasteboard's file URLs to `onFiles`; false when it holds none.
    func takeFiles(from pasteboard: NSPasteboard) -> Bool {
        let urls =
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onFiles(urls)
        return true
    }
}
