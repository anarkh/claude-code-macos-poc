import AppKit
import SwiftUI

struct NativeComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let enabled: Bool
    let focusRequest: Int
    let onSend: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 1, height: 102), textContainer: nil)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 16, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize.height = .greatestFiniteMagnitude
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.isEditable = enabled
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier("chinese-input")
        textView.setAccessibilityLabel("任务输入，回车换行，Command Return 自动翻译并发送")
        scrollView.documentView = textView
        textView.onSend = onSend
        textView.requestFocus(focusRequest)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ComposerTextView else { return }
        textView.isEditable = enabled
        textView.onSend = onSend
        // SwiftUI updates must not replace the IME's marked text while composing.
        if !textView.hasMarkedText(), textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            let location = min(selection.location, length)
            textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        }
        textView.needsDisplay = true
        textView.requestFocus(focusRequest)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        (scrollView.documentView as? NSTextView)?.delegate = nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposerTextView
        init(_ parent: NativeComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            textView.needsDisplay = true
        }
    }
}

private final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    private let retainedEditorStorage: NSTextStorage?
    private let placeholderStorage = NSTextStorage()
    private let placeholderLayout = NSLayoutManager()
    private let placeholderContainer = NSTextContainer(size: .zero)
    private var lastFocusRequest = 0
    private var focusPending = false

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        if let container {
            retainedEditorStorage = nil
            super.init(frame: frameRect, textContainer: container)
        } else {
            // This designated initializer does not create a text system for nil.
            let storage = NSTextStorage()
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: frameRect.width,
                                                        height: CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            retainedEditorStorage = storage
            super.init(frame: frameRect, textContainer: container)
        }
        preparePlaceholder()
    }

    required init?(coder: NSCoder) {
        retainedEditorStorage = nil
        super.init(coder: coder)
        preparePlaceholder()
    }

    private func preparePlaceholder() {
        placeholderStorage.addLayoutManager(placeholderLayout)
        placeholderLayout.addTextContainer(placeholderContainer)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), let textContainer else { return }
        var attributes = typingAttributes
        attributes[.font] = font ?? NSFont.systemFont(ofSize: 14)
        attributes[.foregroundColor] = NSColor.labelColor.withAlphaComponent(0.78)
        placeholderStorage.setAttributedString(NSAttributedString(string: "描述要完成的任务…", attributes: attributes))
        placeholderContainer.containerSize = textContainer.containerSize
        placeholderContainer.lineFragmentPadding = textContainer.lineFragmentPadding
        placeholderLayout.drawGlyphs(forGlyphRange: placeholderLayout.glyphRange(for: placeholderContainer),
                                     at: textContainerOrigin)
    }

    func requestFocus(_ request: Int) {
        guard request != lastFocusRequest else { return }
        lastFocusRequest = request
        focusPending = isEditable
        applyPendingFocus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPendingFocus()
    }

    private func applyPendingFocus() {
        guard focusPending, let window else { return }
        focusPending = false
        window.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36, modifiers == .command, !hasMarkedText() {
            onSend?()
            return
        }
        super.keyDown(with: event)
    }
}
