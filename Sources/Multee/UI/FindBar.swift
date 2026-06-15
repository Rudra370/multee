import AppKit

/// VS Code-style in-editor find/replace bar: a search field + Match-Case / Whole-Word / Regex toggles, a
/// match counter, prev/next, close, and a disclosure chevron that expands a Replace row (replace current /
/// replace all). Pure UI — the owning `EditorViewController` reads `query`/`replaceText`/`matchCase`/
/// `wholeWord`/`regex`, does the searching + replacing, and pushes the count back via `setCount`/`setInvalid`.
final class FindBar: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    let replaceField = NSTextField()
    private let disclosure = PointerButton()
    private let caseBtn = PointerButton()
    private let wordBtn = PointerButton()
    private let regexBtn = PointerButton()
    private let countLabel = NSTextField(labelWithString: "")
    private let prevBtn = PointerButton()
    private let nextBtn = PointerButton()
    private let closeBtn = PointerButton()
    private let replaceBtn = PointerButton()
    private let replaceAllBtn = PointerButton()
    private var replaceRow: NSStackView!

    var onChange: (() -> Void)?   // query or a toggle changed → recompute
    var onNext: (() -> Void)?
    var onPrev: (() -> Void)?
    var onClose: (() -> Void)?
    var onReplace: (() -> Void)?
    var onReplaceAll: (() -> Void)?

    var query: String { field.stringValue }
    var replaceText: String { replaceField.stringValue }
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

        configField(field, "Find")
        configField(replaceField, "Replace")
        replaceField.delegate = self

        configIcon(disclosure, "chevron.right", "Toggle Replace", #selector(toggleReplace))
        configToggle(caseBtn, "Aa", "Match Case", matchCase)
        configToggle(wordBtn, "ab", "Whole Word", wholeWord)
        configToggle(regexBtn, ".*", "Regular Expression", regex)

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = NSColor(white: 0.6, alpha: 1)
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true

        configIcon(prevBtn, "chevron.up", "Previous match (⇧⏎)", #selector(prevTapped))
        configIcon(nextBtn, "chevron.down", "Next match (⏎)", #selector(nextTapped))
        configIcon(closeBtn, "xmark", "Close (Esc)", #selector(closeTapped))
        configTextButton(replaceBtn, "Replace", "Replace (⏎)", #selector(replaceTapped))
        configTextButton(replaceAllBtn, "All", "Replace All", #selector(replaceAllTapped))

        let findRow = NSStackView(views: [disclosure, field, caseBtn, wordBtn, regexBtn,
                                          countLabel, prevBtn, nextBtn, closeBtn])
        findRow.spacing = 4; findRow.alignment = .centerY

        // Spacer keeps the replace field aligned under the find field (past the disclosure chevron).
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        replaceRow = NSStackView(views: [spacer, replaceField, replaceBtn, replaceAllBtn])
        replaceRow.spacing = 4; replaceRow.alignment = .centerY
        replaceRow.isHidden = true

        let outer = NSStackView(views: [findRow, replaceRow])
        outer.orientation = .vertical
        outer.spacing = 5
        outer.alignment = .leading
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            outer.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            field.widthAnchor.constraint(equalToConstant: 210),
            replaceField.widthAnchor.constraint(equalTo: field.widthAnchor),
            spacer.widthAnchor.constraint(equalTo: disclosure.widthAnchor),   // align replace field under find field
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func focusField() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: field.stringValue.count)
    }

    /// Expand the Replace row (the ⌥⌘F "Find and Replace" entry point).
    func expandReplace() {
        if replaceRow.isHidden { toggleReplace() }
    }

    func setCount(current: Int, total: Int) {
        countLabel.stringValue = total == 0 ? (query.isEmpty ? "" : "No results") : "\(current) of \(total)"
    }

    /// Tint the field red on an invalid regex.
    func setInvalid(_ invalid: Bool) {
        field.textColor = invalid ? NSColor(red: 1, green: 0.45, blue: 0.45, alpha: 1) : .labelColor
    }

    // MARK: Build helpers

    private func configField(_ f: NSTextField, _ placeholder: String) {
        f.placeholderString = placeholder
        f.font = .systemFont(ofSize: 12)
        f.focusRingType = .none
        f.delegate = self
        f.translatesAutoresizingMaskIntoConstraints = false
    }

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

    private func configTextButton(_ b: NSButton, _ title: String, _ tip: String, _ action: Selector) {
        b.title = title
        b.bezelStyle = .rounded
        b.font = .systemFont(ofSize: 11)
        b.toolTip = tip
        b.target = self
        b.action = action
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func toggleReplace() {
        replaceRow.isHidden.toggle()
        disclosure.image = NSImage(systemSymbolName: replaceRow.isHidden ? "chevron.right" : "chevron.down",
                                   accessibilityDescription: "Toggle Replace")
    }
    @objc private func toggleTapped() { onChange?() }
    @objc private func nextTapped() { onNext?() }
    @objc private func prevTapped() { onPrev?() }
    @objc private func closeTapped() { onClose?() }
    @objc private func replaceTapped() { onReplace?() }
    @objc private func replaceAllTapped() { onReplaceAll?() }

    // MARK: Field events

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === field { onChange?() }   // editing Replace doesn't re-search
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        let inReplace = (control === replaceField)
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            if inReplace { onReplace?() }
            else if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { onPrev?() } else { onNext?() }
            return true
        case #selector(NSResponder.cancelOperation(_:)): onClose?(); return true
        default: return false
        }
    }

    // MARK: Dev harness

    func setQuery(_ s: String) { field.stringValue = s }
    func setReplace(_ s: String) { replaceField.stringValue = s }
    func debugToggle(_ which: String) {
        let b = which == "case" ? caseBtn : which == "word" ? wordBtn : regexBtn
        b.state = b.state == .on ? .off : .on
    }
}
