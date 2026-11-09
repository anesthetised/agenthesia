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
    /// Each increase moves keyboard focus to the text (Session → Focus Composer).
    var focusRequests = 0
    /// Text to put at the caret, such as an Ask agent quote; each one is inserted once.
    var insertion: ComposerInsertion?
    /// The form docked above the text, whose current step the text answers (#326).
    var form: DockedInput?
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
                isEditable: isEnabled && form?.takesText != false,
                onCommand: { handle($0, matches: matches) },
                onFiles: { if isEnabled && attachmentsEditable { Self.add($0, to: &attachments) } },
                onShortcut: { handleShortcut($0, matches: matches) },
                onKey: pickChoice,
                focusRequests: focusRequests,
                insertion: insertion,
                label: form == nil ? "Message" : "Answer"
            )
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(form?.placeholder ?? "Message the agent…")
                        .foregroundStyle(Color(nsColor: .placeholderTextColor)).lineLimit(1)
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
                empty: text.isEmpty && attachments.isEmpty,
                answering: form != nil
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
        case .decline: form?.decline()
        case .movePick(let offset): form?.movePick(by: offset)
        case .ignore: break
        }
        return true
    }

    /// 1–9 in an empty composer pick the docked form's choices.
    private func pickChoice(_ event: NSEvent) -> Bool {
        guard isEnabled, let form,
            let index = Self.choiceIndex(
                event.charactersIgnoringModifiers,
                modifiers: event.modifierFlags,
                empty: text.isEmpty,
                choices: form.choices.count
            )
        else { return false }
        form.pick(index)
        return true
    }

    /// The choice a digit key picks: 1–9 without ⌘, ⌃ or ⌥, while the composer is empty, so a typed answer can still
    /// hold digits.
    static func choiceIndex(_ characters: String?, modifiers: NSEvent.ModifierFlags, empty: Bool, choices: Int) -> Int?
    {
        guard empty, modifiers.intersection([.command, .control, .option]).isEmpty,
            let characters, characters.count == 1, let digit = Int(characters), (1...9).contains(digit),
            digit <= choices
        else { return nil }
        return digit - 1
    }

    enum KeyAction: Equatable {
        case select(Int), complete(Int), dismiss, submit, sendNow, sendAllNow, recall, stop
        /// Only while a form is docked (#326).
        case decline, movePick(Int), ignore
    }

    /// What a key command does with `matches` commands listed; nil leaves it to the text view.
    static func keyAction(
        _ selector: Selector,
        matches: Int,
        selection: Int,
        lineBreak: Bool,
        command: Bool = false,
        shift: Bool = false,
        empty: Bool = false,
        answering: Bool = false
    ) -> KeyAction? {
        // While a form is docked, Return answers and never queues, Escape declines and ↑ ↓ move a choice (#326).
        if answering {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)): return command ? .stop : .decline
            case #selector(NSResponder.insertNewline(_:)): return command ? .ignore : lineBreak ? nil : .submit
            case #selector(NSResponder.moveUp(_:)) where empty: return .movePick(-1)
            case #selector(NSResponder.moveDown(_:)) where empty: return .movePick(1)
            default: return nil
            }
        }
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

/// Text for the composer to insert at its caret; a new value is inserted even when the text repeats.
struct ComposerInsertion: Equatable {
    let id = UUID()
    let text: String
}

/// A plain-text `NSTextView` that grows with its content and hands file drops and pastes to `onFiles`.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    /// Return true to consume a key command such as `insertNewline:`.
    var onCommand: (Selector) -> Bool
    var onFiles: ([URL]) -> Void
    var onShortcut: (NSEvent) -> Bool = { _ in false }
    /// Return true to consume a key before the text view types it.
    var onKey: (NSEvent) -> Bool = { _ in false }
    var focusRequests = 0
    var insertion: ComposerInsertion?
    var label = "Message"

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
        if context.coordinator.focusRequests != focusRequests {
            context.coordinator.focusRequests = focusRequests
            textView.window?.makeFirstResponder(textView)
        }
        if let insertion, context.coordinator.insertionID != insertion.id {
            context.coordinator.insertionID = insertion.id
            // Past the view update, as the edit writes the text binding.
            Task { @MainActor in textView.insertBlock(insertion.text) }
        }
    }

    private func update(_ textView: FileTextView, coordinator: Coordinator) {
        coordinator.parent = self
        textView.onFiles = onFiles
        textView.onShortcut = onShortcut
        textView.onKey = onKey
        textView.isEditable = isEditable
        textView.setAccessibilityLabel(label)
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
        var focusRequests: Int
        /// The last insertion done, or the one pending when the view was made, which belongs to an earlier one.
        var insertionID: UUID?

        init(_ parent: ComposerTextView) {
            self.parent = parent
            focusRequests = parent.focusRequests
            insertionID = parent.insertion?.id
        }

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
    var onKey: (NSEvent) -> Bool = { _ in false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onShortcut(event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !onKey(event) { super.keyDown(with: event) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    /// Inserts `text` at the caret, after any selected text, on lines of its own, as a typed edit that Undo reverts.
    func insertBlock(_ text: String) {
        let location = NSMaxRange(selectedRange())
        insertText(
            Self.block(text, after: (string as NSString).substring(to: location)),
            replacementRange: NSRange(location: location, length: 0)
        )
    }

    /// `text` with a line break before it unless `before` ends a line, and one after it for what the user types next.
    static func block(_ text: String, after before: String) -> String {
        (before.isEmpty || before.hasSuffix("\n") ? "" : "\n") + text + "\n"
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
