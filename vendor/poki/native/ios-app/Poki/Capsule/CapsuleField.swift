import SwiftUI
import UIKit

/// The message field with app capsules (ESP-377). `text` is the plain text and the only
/// source: an app's name in it shows as a capsule, the capsule is one character to the caret and to
/// backspace, and reading the field gives the plain text back with the names in place.
struct CapsuleField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var maxLines = 6
    var maxHeight: CGFloat = 200
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Whether the message is scrolled away from its first line, for a swipe down on the field: that
    /// swipe scrolls the message back, it does not put the keyboard away.
    var scroll: CapsuleScroll? = nil
    /// An upright swipe on the field itself, true for up. The text view's own drag wins over a SwiftUI
    /// gesture around it while it has the keyboard, so the field reads the swipe itself as well.
    var onSwipe: ((Bool) -> Void)? = nil
    /// Return: the keyboard's Send key, as on the current field.
    var onSubmit: () -> Void

    func makeUIView(context: Context) -> CapsuleTextView {
        let view = CapsuleTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = CapsuleTextView.bodyFont
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.returnKeyType = .send
        view.enablesReturnKeyAutomatically = true
        view.isScrollEnabled = true
        view.showsVerticalScrollIndicator = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "capsule.field"
        view.accessibilityLabel = AppLocalization.text(LocalizedStringResource("Message Poki"))
        view.updateFont(for: UIContentSizeCategory(typeSize))
        view.setPlain(text)
        let swipe = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swiped(_:)))
        swipe.delegate = context.coordinator
        swipe.cancelsTouchesInView = false
        view.addGestureRecognizer(swipe)
        return view
    }

    func updateUIView(_ view: CapsuleTextView, context: Context) {
        context.coordinator.parent = self
        view.updateFont(for: UIContentSizeCategory(typeSize))
        view.accessibilityLabel = AppLocalization.text(LocalizedStringResource("Message Poki"))
        // A write from outside (a recommendation, dictation, Send emptying the field): render it whole,
        // caret at the end.
        if view.plainText != text { view.setPlain(text) }
        if focused, !view.isFirstResponder {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !focused, view.isFirstResponder {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: CapsuleTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 280
        let fit = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let font = view.font ?? CapsuleTextView.bodyFont
        let most = (font.lineHeight * CGFloat(maxLines) + view.textContainerInset.top + view.textContainerInset.bottom).rounded(.up)
        return CGSize(width: width, height: min(fit, most, max(maxHeight, font.lineHeight + view.textContainerInset.top + view.textContainerInset.bottom)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: CapsuleField
        /// The message was scrolled away from its first line when the swipe began.
        private var startedScrolled = false

        init(parent: CapsuleField) { self.parent = parent }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n" {
                guard textView.markedTextRange == nil else { return true }
                if let view = textView as? CapsuleTextView { parent.text = view.plainText }
                parent.onSubmit()
                return false
            }
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let view = textView as? CapsuleTextView else { return }
            view.reconcile()
            if parent.text != view.plainText { parent.text = view.plainText }
        }

        @objc func swiped(_ pan: UIPanGestureRecognizer) {
            guard let view = pan.view as? UITextView else { return }
            switch pan.state {
            case .began: startedScrolled = Self.scrolledDown(view)
            case .ended:
                let (move, speed) = (pan.translation(in: view), pan.velocity(in: view))
                guard abs(move.y) > abs(move.x) * 1.5 else { return }
                if move.y < -24 || speed.y < -600 { parent.onSwipe?(true) }
                if move.y > 24 || speed.y > 600, !startedScrolled { parent.onSwipe?(false) }
            default: break
            }
        }

        /// Alongside the text view's own scrolling and selection.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            parent.scroll?.scrolledDown = Self.scrolledDown(scrollView)
        }

        /// Away from the first line of a message taller than the field. A message that fits can sit a
        /// few points off (the caret's line brought into view), and that is not scrolled.
        private static func scrolledDown(_ view: UIScrollView) -> Bool {
            view.contentSize.height > view.bounds.height + 1 && view.contentOffset.y + view.adjustedContentInset.top > 1
        }

        func textViewDidBeginEditing(_ textView: UITextView) { if !parent.focused { parent.focused = true } }
        func textViewDidEndEditing(_ textView: UITextView) { if parent.focused { parent.focused = false } }
    }
}

/// Where the message field is scrolled, read when a swipe on the field starts.
final class CapsuleScroll {
    var scrolledDown = false
}

final class CapsuleTextView: UITextView {
    static var bodyFont: UIFont { .preferredFont(forTextStyle: .body) }
    private var requestedCategory: UIContentSizeCategory?
    private var needsFontRefresh = false

    func updateFont(for category: UIContentSizeCategory) {
        requestedCategory = category
        refreshFont()
    }

    private func refreshFont() {
        guard markedTextRange == nil else { needsFontRefresh = true; return }
        let traits = traitCollection.modifyingTraits {
            $0.preferredContentSizeCategory = requestedCategory ?? traitCollection.preferredContentSizeCategory
        }
        let next = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        guard needsFontRefresh || font != next else { return }
        needsFontRefresh = false
        font = next
        redraw()
        invalidateIntrinsicContentSize()
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        // The pills are pictures drawn for one appearance and one text size: draw them again.
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]) { (view: CapsuleTextView, _: UITraitCollection) in
            view.needsFontRefresh = true
            view.refreshFont()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not implemented") }

    override var keyCommands: [UIKeyCommand]? {
        let newline = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(insertLineBreak))
        newline.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [newline]
    }

    @objc private func insertLineBreak(_ command: UIKeyCommand) {
        guard markedTextRange == nil, let selection = selectedTextRange else { return }
        replace(selection, withText: "\n")
        delegate?.textViewDidChange?(self)
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? Self.bodyFont, .foregroundColor: UIColor.label]
    }

    /// The field's text with each capsule read back as the words it stands for.
    var plainText: String { Self.plain(textStorage, in: NSRange(location: 0, length: textStorage.length)) }

    /// Replaces everything with `plain`, caret at the end.
    func setPlain(_ plain: String) {
        textStorage.setAttributedString(render(CapsuleText.segments(plain)))
        selectedRange = NSRange(location: textStorage.length, length: 0)
        typingAttributes = baseAttributes
    }

    /// After every edit: names that are now whole become capsules, and capsules whose words are no
    /// longer a name (a letter typed against them) become text again. Nothing changes while the
    /// keyboard is still composing (Pinyin before it commits), so the composition is never disturbed.
    func reconcile() {
        guard markedTextRange == nil else { return }
        if needsFontRefresh { refreshFont() }
        let wanted = CapsuleText.segments(plainText)
        guard wanted != segments() else { return }
        replaceKeepingSelection(with: wanted)
    }

    private func redraw() {
        guard markedTextRange == nil else { return }
        replaceKeepingSelection(with: CapsuleText.segments(plainText))
    }

    private func replaceKeepingSelection(with wanted: [CapsuleText.Segment]) {
        let selection = selectedRange
        let start = plainOffset(selection.location)
        let end = plainOffset(selection.location + selection.length)
        textStorage.beginEditing()
        textStorage.setAttributedString(render(wanted))
        textStorage.endEditing()
        let from = storageOffset(start), to = storageOffset(end)
        selectedRange = NSRange(location: from, length: max(0, to - from))
        typingAttributes = baseAttributes
    }

    // MARK: Plain text in and out

    private func render(_ segments: [CapsuleText.Segment]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = font ?? Self.bodyFont
        for segment in segments {
            switch segment {
            case .text(let text):
                out.append(NSAttributedString(string: text, attributes: baseAttributes))
            case .app(let app, let text):
                let pill = PillTextAttachment(pillData: PillTextAttachmentData(app: app, text: text, font: font), traits: traitCollection)
                let one = NSMutableAttributedString(attachment: pill)
                one.addAttributes(baseAttributes, range: NSRange(location: 0, length: one.length))
                out.append(one)
            }
        }
        return out
    }

    private func segments() -> [CapsuleText.Segment] {
        var out: [CapsuleText.Segment] = []
        let string = textStorage.string as NSString
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            if let pill = value as? PillTextAttachment {
                out.append(.app(pill.pillData.app, pill.pillData.text))
            } else if case .text(let before)? = out.last {
                out[out.count - 1] = .text(before + string.substring(with: range))
            } else {
                out.append(.text(string.substring(with: range)))
            }
        }
        return out
    }

    static func plain(_ storage: NSAttributedString, in range: NSRange) -> String {
        var out = ""
        let string = storage.string as NSString
        storage.enumerateAttribute(.attachment, in: range) { value, run, _ in
            if let pill = value as? PillTextAttachment {
                out += pill.pillData.text
            } else {
                out += string.substring(with: run)
            }
        }
        return out
    }

    /// Where a position in the field falls in the plain text.
    private func plainOffset(_ location: Int) -> Int {
        Self.plain(textStorage, in: NSRange(location: 0, length: min(location, textStorage.length))).utf16.count
    }

    /// Where a position in the plain text falls in the field; inside a capsule's words, after the capsule.
    private func storageOffset(_ plain: Int) -> Int {
        var seen = 0
        var result = textStorage.length
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, run, stop in
            let length = (value as? PillTextAttachment)?.pillData.text.utf16.count ?? run.length
            if plain <= seen + length {
                if let _ = value as? PillTextAttachment {
                    result = plain == seen ? run.location : run.location + 1
                } else {
                    result = run.location + (plain - seen)
                }
                stop.pointee = true
                return
            }
            seen += length
        }
        return result
    }

    // MARK: Copy, cut and paste carry plain text

    override func copy(_ sender: Any?) {
        guard selectedRange.length > 0 else { return }
        UIPasteboard.general.string = Self.plain(textStorage, in: selectedRange)
    }

    override func cut(_ sender: Any?) {
        guard selectedRange.length > 0, let range = selectedTextRange else { return }
        copy(sender)
        replace(range, withText: "")
        delegate?.textViewDidChange?(self)
    }

    override func paste(_ sender: Any?) {
        guard let string = UIPasteboard.general.string, let range = selectedTextRange else { return }
        replace(range, withText: string)
        delegate?.textViewDidChange?(self)
    }

    override var accessibilityValue: String? {
        get { plainText }
        set {}
    }
}
