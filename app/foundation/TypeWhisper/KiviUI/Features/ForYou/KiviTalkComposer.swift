import SwiftUI
import AppKit

/// Placeholder and input share NSTextView's font, container and glyph layout.
/// This avoids aligning a SwiftUI Text baseline with an unrelated native caret.
struct KiviTalkComposer: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    @Binding var height: CGFloat
    var caretToEndRequest: UUID? = nil
    var onSend: () -> Void
    @Environment(\.isEnabled) private var enabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ComposerScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        let editor = ComposerTextView(frame: .zero)
        editor.drawsBackground = false
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineFragmentPadding = 4
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.font = NSFont(name: "Matter-Regular", size: 17) ?? .systemFont(ofSize: 17)
        editor.textColor = NSColor(KiviTheme.ink)
        editor.insertionPointColor = NSColor(KiviTheme.ink)
        editor.typingAttributes = [.font: NSFont(name: "Matter-Regular", size: 17) ?? .systemFont(ofSize: 17), .foregroundColor: NSColor(KiviTheme.ink)]
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel("message to Kivi")
        editor.setAccessibilityHelp("Press Return to send. Shift-Return starts a new line.")
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        editor.isEditable = enabled
        editor.onSend = onSend
        editor.onHeightChange = { value in
            guard abs(context.coordinator.parent.height - value) > 0.5 else { return }
            context.coordinator.parent.height = value
        }
        editor.textColor = NSColor(KiviTheme.ink)
        editor.insertionPointColor = NSColor(KiviTheme.ink)
        context.coordinator.updateText(editor)
        if !editor.hasMarkedText() {
            editor.typingAttributes = [.font: NSFont(name: "Matter-Regular", size: 17) ?? .systemFont(ofSize: 17), .foregroundColor: NSColor(KiviTheme.ink)]
        }
        editor.needsDisplay = true
        editor.reportHeight()
        if focused && enabled && editor.window?.firstResponder !== editor {
            DispatchQueue.main.async { [weak editor] in
                guard let editor, editor.isEditable, let window = editor.window else { return }
                window.makeFirstResponder(editor)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: KiviTalkComposer
        init(_ parent: KiviTalkComposer) { self.parent = parent }
        private var lastCaretToEndRequest: UUID?

        func updateText(_ editor: ComposerTextView) {
            let text = parent.text
            if editor.string != text {
                let selection = editor.selectedRange()
                editor.string = text
                editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            }
            if let request = parent.caretToEndRequest, request != lastCaretToEndRequest {
                lastCaretToEndRequest = request
                let end = NSRange(location: (editor.string as NSString).length, length: 0)
                editor.setSelectedRange(end)
                editor.scrollRangeToVisible(end)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? ComposerTextView else { return }
            parent.text = editor.string
            editor.needsDisplay = true
            editor.reportHeight()
        }
        func textDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func textDidEndEditing(_ notification: Notification) { parent.focused = false }
    }

    final class ComposerTextView: NSTextView {
        var onSend: (() -> Void)?
        var onHeightChange: ((CGFloat) -> Void)?

        func reportHeight() {
            guard let layoutManager, let textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let extraLine = layoutManager.extraLineFragmentTextContainer === textContainer ? layoutManager.extraLineFragmentRect.maxY : 0
            let measured = max(layoutManager.usedRect(for: textContainer).maxY, extraLine) + textContainerInset.height * 2
            let target = min(140, max(54, ceil(measured)))
            DispatchQueue.main.async { [weak self] in self?.onHeightChange?(target) }
        }

        override func keyDown(with event: NSEvent) {
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            if isReturn && isEditable && !hasMarkedText() {
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if modifiers.contains(.shift) || modifiers.contains(.option) || modifiers.contains(.control) {
                    insertNewline(nil)
                } else if !event.isARepeat && !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onSend?()
                }
                return
            }
            super.keyDown(with: event)
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, let font, let textContainer else { return }
            let storage = NSTextStorage(string: "tell me what Kivi could do better…", attributes: [
                .font: font,
                .foregroundColor: NSColor(KiviTheme.muted).withAlphaComponent(0.6)
            ])
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: textContainer.size)
            container.lineFragmentPadding = textContainer.lineFragmentPadding
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            let glyphs = layout.glyphRange(for: container)
            layout.drawGlyphs(forGlyphRange: glyphs, at: textContainerOrigin)
        }
    }

    final class ComposerScrollView: NSScrollView {
        override func layout() {
            super.layout()
            guard let editor = documentView as? ComposerTextView else { return }
            if abs(editor.frame.width - contentSize.width) > 0.5 {
                editor.setFrameSize(NSSize(width: contentSize.width, height: max(contentSize.height, editor.frame.height)))
            }
            editor.reportHeight()
        }
    }
}
