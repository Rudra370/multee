import AppKit

/// VS Code-style in-editor find bar: a search field + Match-Case / Whole-Word / Regex toggles, a match
/// counter, prev/next, and close. Pure UI — the owning `EditorViewController` reads `query`/`matchCase`/
/// `wholeWord`/`regex`, does the searching, and pushes the count back via `setCount` / `setInvalid`.
final class FindBar: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    private let caseBtn = NSButton()
    private let wordBtn = NSButton()
    private let regexBtn = NSButton()
    private let countLabel = NSTextField(labelWithString: "")
    private let prevBtn = NSButton()
    private let nextBtn = NSButton()
    private let closeBtn = NSButton()

    var onChange: (() -> Void)?   // query or a toggle changed → recompute
    var onNext: (() -> Void)?
    var onPrev: (() -> Void)?
    var onClose: (() -> Void)?

    var query: String { field.stringValue }
    var matchCase: Bool { caseBtn.state == .on }
    var wholeWord: Bool { wordBtn.state == .on }
    var regex: Bool { regexBtn.state == .on }

    init(matchCase: Bool, wholeWord: Bool, regex: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.17, alpha: 1).cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0.30, alpha: 1).cgColor
        shadow = NSShadow()
        layer?.shadowColor = .black; layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 10; layer?.shadowOffset = CGSize(width: 0, height: -2)

        field.placeholderString = "Find"
        field.font = .systemFont(ofSize: 12)
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        configToggle(caseBtn, "Aa", "Match Case", matchCase)
        configToggle(wordBtn, "ab", "Whole Word", wholeWord)
        configToggle(regexBtn, ".*", "Regular Expression", regex)

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = NSColor(white: 0.6, alpha: 1)
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        configIcon(prevBtn, "chevron.up", "Previous match (⇧⏎)", #selector(prevTapped))
        configIcon(nextBtn, "chevron.down", "Next match (⏎)", #selector(nextTapped))
        configIcon(closeBtn, "xmark", "Close (Esc)", #selector(closeTapped))

        let stack = NSStackView(views: [field, caseBtn, wordBtn, regexBtn, countLabel, prevBtn, nextBtn, closeBtn])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            field.widthAnchor.constraint(equalToConstant: 210),
            countLabel.widthAnchor.constraint(equalToConstant: 64),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func focusField() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: field.stringValue.count)
    }

    func setCount(current: Int, total: Int) {
        countLabel.stringValue = total == 0 ? (query.isEmpty ? "" : "No results") : "\(current) of \(total)"
        countLabel.textColor = total == 0 && !query.isEmpty ? NSColor(white: 0.7, alpha: 1) : NSColor(white: 0.6, alpha: 1)
    }

    /// Tint the field red on an invalid regex.
    func setInvalid(_ invalid: Bool) {
        field.textColor = invalid ? NSColor(red: 1, green: 0.45, blue: 0.45, alpha: 1) : .labelColor
    }

    // MARK: Build helpers

    private func configToggle(_ b: NSButton, _ title: String, _ tip: String, _ on: Bool) {
        b.title = title
        b.bezelStyle = .recessed
        b.setButtonType(.pushOnPushOff)
        b.showsBorderOnlyWhileMouseInside = false
        b.state = on ? .on : .off
        b.toolTip = tip
        b.font = .systemFont(ofSize: 11, weight: .semibold)
        b.target = self
        b.action = #selector(toggleTapped)
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 26).isActive = true
    }

    private func configIcon(_ b: NSButton, _ symbol: String, _ tip: String, _ action: Selector) {
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.imagePosition = .imageOnly
        b.isBordered = false
        b.contentTintColor = NSColor(white: 0.82, alpha: 1)
        b.toolTip = tip
        b.target = self
        b.action = action
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func toggleTapped() { onChange?() }
    @objc private func nextTapped() { onNext?() }
    @objc private func prevTapped() { onPrev?() }
    @objc private func closeTapped() { onClose?() }

    // MARK: Field events

    func controlTextDidChange(_ obj: Notification) { onChange?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            // ⇧⏎ = previous, ⏎ = next.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { onPrev?() } else { onNext?() }
            return true
        case #selector(NSResponder.cancelOperation(_:)): onClose?(); return true
        default: return false
        }
    }

    // MARK: Dev harness

    func setQuery(_ s: String) { field.stringValue = s }
    func debugToggle(_ which: String) {
        let b = which == "case" ? caseBtn : which == "word" ? wordBtn : regexBtn
        b.state = b.state == .on ? .off : .on
    }
}
