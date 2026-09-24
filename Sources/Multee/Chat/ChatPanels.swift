import AppKit

/// A text button with a closure: `.primary` (accent fill), `.secondary` (faint chip), `.danger` (red text).
final class ChatActionButton: PointerButton {
    enum Kind { case primary, secondary, danger }
    private let handler: () -> Void

    init(_ title: String, kind: Kind, size: CGFloat = 12, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 6
        let fg: NSColor
        switch kind {
        case .primary:
            layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            fg = .white
        case .secondary:
            layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
            fg = NSColor(white: 0.88, alpha: 1)
        case .danger:
            layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
            fg = ChatStyle.red
        }
        attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: fg, .font: NSFont.systemFont(ofSize: size, weight: .medium)])
        target = self
        self.action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let s = attributedTitle.size()
        return NSSize(width: ceil(s.width) + 22, height: ceil(s.height) + 10)
    }

    @objc private func fire() { handler() }
    func press() { handler() }

    /// Opt-in keyboard focus (the trust button): a white ring while focused, space or ⏎ presses it. NSButton
    /// only takes focus with the system's Full Keyboard Access on, so this doesn't lean on that.
    var takesKeyboard = false
    // Other action buttons keep NSButton's own rules (focusable with Full Keyboard Access).
    override var acceptsFirstResponder: Bool { takesKeyboard ? !isHidden : super.acceptsFirstResponder }
    override var canBecomeKeyView: Bool { takesKeyboard ? !isHidden : super.canBecomeKeyView }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder() || takesKeyboard
        if ok, takesKeyboard { setRing(true) }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        if takesKeyboard { setRing(false) }
        return super.resignFirstResponder() || takesKeyboard
    }
    private func setRing(_ on: Bool) {
        layer?.borderWidth = on ? 2 : 0
        layer?.borderColor = NSColor(white: 1, alpha: 0.85).cgColor
    }
    var hasRing: Bool { (layer?.borderWidth ?? 0) > 0 }
    override func keyDown(with event: NSEvent) {
        guard takesKeyboard else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 49, 36, 76: press()                  // space, return, keypad enter
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - Prompt panel (permission · question · plan)

/// A choice the chat itself asks — rewind what, turn on bypass, which other model — shown like Claude's own
/// prompts (in the card, keyboard-driven) rather than as a modal alert, as the terminal UI does.
struct ChatLocalCard {
    struct Choice {
        let title: String
        var detail: String? = nil
        let action: () -> Void
    }
    var title: String
    var detail: String?
    var choices: [Choice]
    var field: (placeholder: String, action: (String) -> Void)? = nil    // a text row after the choices
    var hint: String
    var onCancel: () -> Void                                               // esc
    var affirmative = 0                                                    // the "yes" choice (harness: `chatConfirm:ok`)
}

/// The card Claude waits on — a tool permission, an `AskUserQuestion`, or an `ExitPlanMode` plan approval —
/// driven like the terminal UI: every choice is a numbered row under a ❯ cursor. ↑/↓ move, ⏎ confirms,
/// 1–9 pick directly, esc denies / skips. Questions come one at a time (a tab each: ←/→ or tab to switch,
/// then a Submit step). The "Type something…" / "tell Claude…" row is a text field the cursor walks into.
final class ChatPromptPanel: NSView, NSTextFieldDelegate {
    var onAnswer: ((ChatSession.PromptAnswer) -> Void)?
    private let stack = NSStackView()
    private var prompt: ChatPrompt?
    private var style = ChatStyle(size: 13)
    private var cwd = ""
    private var fontSize: CGFloat = 13
    private(set) var requestID: String?

    // The choice list on screen: a row per choice and what picking it does.
    private var rows: [ChatChoiceRow] = []
    private var picks: [() -> Void] = []
    private var cursor = 0
    private var planScroll: NSScrollView?

    // Questions: one page each, then the Submit step (page == questions.count).
    private var questions: [[String: Any]] = []
    private var page = 0
    private var chosen: [Int: Set<String>] = [:]    // question → picked option labels
    private var typed: [Int: String] = [:]          // question → "Type something…" text
    private var feedbackText = ""                   // permission / plan: the "tell Claude…" text
    private var local: ChatLocalCard?               // a card the chat asks itself (instead of Claude's prompt)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor(white: 0.155, alpha: 1).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = ChatStyle.amber.withAlphaComponent(0.55).cgColor
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 10, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    func show(_ p: ChatPrompt, style: ChatStyle, cwd: String) {
        guard p.requestID != requestID else { return }
        requestID = p.requestID
        prompt = p
        self.style = style
        self.cwd = cwd
        fontSize = style.size
        questions = p.input["questions"] as? [[String: Any]] ?? []
        page = 0; chosen = [:]; typed = [:]; feedbackText = ""
        local = nil
        layer?.borderColor = ChatStyle.amber.withAlphaComponent(0.55).cgColor   // Claude is waiting on you
        rebuild()
    }

    /// One of the chat's own questions, in the same card and keys (a neutral border: Claude isn't waiting).
    func showLocal(_ card: ChatLocalCard, style: ChatStyle) {
        requestID = "local-" + UUID().uuidString
        prompt = nil
        local = card
        self.style = style
        fontSize = style.size
        questions = []; page = 0; feedbackText = ""
        layer?.borderColor = NSColor(white: 0.36, alpha: 1).cgColor
        rebuild()
    }

    /// Put the keyboard on the card (its text row, when that's where the cursor is).
    func focusCard() {
        window?.makeFirstResponder(self)
        if rows.indices.contains(cursor), rows[cursor].field != nil { setCursor(cursor) }
    }

    /// Esc from elsewhere (the message box).
    func cancel() { dismiss() }

    func clear() { requestID = nil; prompt = nil; local = nil }

    // MARK: Building

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []; picks = []; planScroll = nil
        if let local { buildLocal(local); setCursor(0, focusField: false); return }
        guard let p = prompt else { return }
        var start = 0
        switch p.kind {
        case .permission: buildPermission(p)
        case .plan: buildPlan(p)
        case .question: start = buildQuestionPage()
        }
        setCursor(start, focusField: false)
    }

    private func label(_ s: String, font: NSFont, color: NSColor, lines: Int = 1) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = font
        l.textColor = color
        l.maximumNumberOfLines = lines
        l.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        l.isSelectable = true
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }

    /// A view that spans the card's inner width.
    private func addFull(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
    }

    private func addChoice(_ title: String, detail: String? = nil, mark: ChatChoiceRow.Mark = .none,
                           field placeholder: String? = nil, text: String = "", pick: @escaping () -> Void) {
        let row = ChatChoiceRow(number: rows.count + 1, title: title, detail: detail, mark: mark,
                                fieldPlaceholder: placeholder, fieldText: text, fontSize: fontSize)
        let i = rows.count
        row.onClick = { [weak self] in self?.setCursor(i, focusField: true); self?.pick(i) }
        row.field?.delegate = self
        rows.append(row)
        picks.append(pick)
        addFull(row)
    }

    private func addHint(_ s: String) {
        stack.addArrangedSubview(label(s, font: .systemFont(ofSize: fontSize - 3), color: ChatStyle.faint))
    }

    private func buildLocal(_ card: ChatLocalCard) {
        stack.addArrangedSubview(label(card.title, font: .systemFont(ofSize: fontSize, weight: .semibold), color: ChatStyle.heading, lines: 3))
        if let d = card.detail, !d.isEmpty {
            addFull(label(d, font: .systemFont(ofSize: fontSize - 2), color: ChatStyle.dim, lines: 8))
        }
        for c in card.choices { addChoice(c.title, detail: c.detail) { c.action() } }
        if let f = card.field {
            addChoice("", field: f.placeholder) { [weak self] in f.action(self?.feedbackText ?? "") }
        }
        addHint(card.hint)
    }

    private func buildPermission(_ p: ChatPrompt) {
        stack.addArrangedSubview(label("Claude wants to use \(ChatRender.toolTitle(p.toolName))", font: .systemFont(ofSize: fontSize, weight: .semibold), color: ChatStyle.heading))
        let detail = ChatRender.permissionDetail(p, style: style, cwd: cwd)
        if detail.length > 0 {
            let tv = NSTextField(labelWithAttributedString: detail)
            tv.maximumNumberOfLines = 14
            tv.lineBreakMode = .byTruncatingTail
            tv.isSelectable = true
            tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(tv)
            tv.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -28).isActive = true
        }
        if let reason = p.reason, !reason.isEmpty, reason != "This command requires approval" {
            stack.addArrangedSubview(label(reason, font: .systemFont(ofSize: fontSize - 2), color: ChatStyle.dim, lines: 2))
        }
        addChoice("Yes") { [weak self] in self?.onAnswer?(.allow) }
        if let always = Self.alwaysLabel(p.suggestions) {
            addChoice("Yes, and " + always.prefix(1).lowercased() + String(always.dropFirst())) { [weak self] in self?.onAnswer?(.allowAlways) }
        }
        addChoice("", field: "No, and tell Claude what to do differently", text: feedbackText) { [weak self] in self?.denyWithFeedback() }
        addHint("↑↓ select · ⏎ confirm · 1–\(rows.count) pick · esc deny")
    }

    /// "Always allow" wording for Claude's suggestions: a rule ("Bash(npm test:*)") or a mode change.
    static func alwaysLabel(_ suggestions: [[String: Any]]) -> String? {
        guard let s = suggestions.first else { return nil }
        switch s["type"] as? String {
        case "setMode":
            return s["mode"] as? String == "acceptEdits" ? "Allow all edits this session" : "Allow for this session"
        case "addRules":
            let rules = (s["rules"] as? [[String: Any]] ?? []).map { r -> String in
                let tool = r["toolName"] as? String ?? ""
                let content = r["ruleContent"] as? String
                return content.map { "\(tool)(\($0.count > 36 ? String($0.prefix(35)) + "…" : $0))" } ?? tool
            }
            let where_ = (s["destination"] as? String) == "session" ? "this session" : "this project"
            return rules.isEmpty ? "Always allow" : "Always allow \(rules.joined(separator: ", ")) in \(where_)"
        default:
            return "Always allow"
        }
    }

    private func buildPlan(_ p: ChatPrompt) {
        stack.addArrangedSubview(label("Claude’s plan is ready", font: .systemFont(ofSize: fontSize, weight: .semibold), color: ChatStyle.heading))
        let plan = ChatMarkdown.render(p.input["plan"] as? String ?? "", style: style)
        let sv = NSScrollView()
        sv.drawsBackground = false
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        let tv = NSTextView()
        tv.isEditable = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.textContainer?.lineFragmentPadding = 0      // line up with the card's title
        tv.textStorage?.setAttributedString(plan)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        sv.documentView = tv
        sv.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sv)
        planScroll = sv
        let measured = ChatMeasurer().height(plan, width: 700) + 12
        NSLayoutConstraint.activate([
            sv.heightAnchor.constraint(equalToConstant: min(300, max(60, measured))),
            sv.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        addChoice("Yes, and auto-accept edits") { [weak self] in self?.onAnswer?(.approvePlan(mode: "acceptEdits")) }
        addChoice("Yes, and manually approve edits") { [weak self] in self?.onAnswer?(.approvePlan(mode: "default")) }
        addChoice("", field: "No, keep planning — tell Claude what to change", text: feedbackText) { [weak self] in self?.denyWithFeedback() }
        addHint("↑↓ select · ⏎ confirm · 1–3 pick · page up/down scroll the plan · esc keep planning")
    }

    /// The current question (or the Submit step); returns the row the cursor starts on.
    private func buildQuestionPage() -> Int {
        if questions.count > 1 { addFull(tabStrip()) }
        guard questions.indices.contains(page) else { buildSubmitStep(); return 0 }
        let q = questions[page]
        let multi = q["multiSelect"] as? Bool ?? false
        if questions.count == 1, let h = q["header"] as? String, !h.isEmpty {
            stack.addArrangedSubview(label(h.uppercased(), font: .systemFont(ofSize: fontSize - 3, weight: .semibold), color: ChatStyle.amber))
        }
        stack.addArrangedSubview(label(q["question"] as? String ?? "", font: .systemFont(ofSize: fontSize, weight: .semibold), color: ChatStyle.heading, lines: 4))
        let picked = chosen[page] ?? []
        let options = q["options"] as? [[String: Any]] ?? []
        for o in options {
            let l = o["label"] as? String ?? "?"
            addChoice(l, detail: o["description"] as? String, mark: multi ? .box(picked.contains(l)) : .check(picked.contains(l))) { [weak self] in
                self?.pickOption(l, multi: multi)
            }
        }
        let n = page
        addChoice("", mark: multi ? .box(!(typed[n] ?? "").isEmpty) : .check(!(typed[n] ?? "").isEmpty),
                  field: "Type something…", text: typed[n] ?? "") { [weak self] in self?.pickTyped(multi: multi) }
        // Multi-select: ⏎ toggles (as in the terminal UI), so moving on is a row of its own.
        if multi { addChoice(questions.count > 1 ? "Next" : "Submit") { [weak self] in self?.advance() } }
        let more = questions.count > 1 ? " · ←→ questions" : ""
        addHint(multi ? "↑↓ move · ⏎ or space toggle · 1–\(rows.count - 1) toggle\(more) · esc skip"
                      : "↑↓ move · ⏎ or 1–\(rows.count) pick\(more) · esc skip")
        // Back on an answered question: start on its answer.
        if !(typed[n] ?? "").isEmpty { return rows.count - 1 }
        return options.firstIndex { picked.contains($0["label"] as? String ?? "") } ?? 0
    }

    private func buildSubmitStep() {
        stack.addArrangedSubview(label("Review your answers", font: .systemFont(ofSize: fontSize, weight: .semibold), color: ChatStyle.heading))
        for (i, q) in questions.enumerated() {
            let name = (q["header"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (q["question"] as? String ?? "Question \(i + 1)")
            let a = answer(i)
            let line = NSMutableAttributedString(string: name + "  ", attributes: [.font: NSFont.systemFont(ofSize: fontSize - 1, weight: .medium), .foregroundColor: ChatStyle.dim])
            line.append(NSAttributedString(string: a ?? "no answer", attributes: [.font: NSFont.systemFont(ofSize: fontSize - 1), .foregroundColor: a == nil ? ChatStyle.faint : ChatStyle.text]))
            let l = NSTextField(labelWithAttributedString: line)
            l.lineBreakMode = .byTruncatingTail
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addFull(l)
        }
        addChoice("Submit answers") { [weak self] in self?.submitAnswers() }
        addChoice("Cancel") { [weak self] in self?.onAnswer?(.deny("The user declined to answer.")) }
        addHint("↑↓ select · ⏎ confirm · ← back · esc skip")
    }

    /// "☐ Features  ☑ Politeness  ✔ Submit" — the question tabs; click one or use ←/→.
    private func tabStrip() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 14
        for i in 0...questions.count {
            let isSubmit = i == questions.count
            let name = isSubmit ? "Submit" : (questions[i]["header"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Question \(i + 1)"
            let glyph = isSubmit ? "✔" : (answer(i) == nil ? "☐" : "☑")
            let current = i == page
            let b = ChatTabLabel(glyph + " " + name, current: current, size: fontSize - 2) { [weak self] in self?.goTo(page: i) }
            row.addArrangedSubview(b)
        }
        row.addArrangedSubview(NSView())
        return row
    }

    // MARK: Answers

    private func pickOption(_ label: String, multi: Bool) {
        if multi {
            var set = chosen[page] ?? []
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
            chosen[page] = set
            if rows.indices.contains(cursor) { rows[cursor].mark = .box(set.contains(label)) }
            refreshTabs()
        } else {
            chosen[page] = [label]
            typed[page] = nil
            advance()
        }
    }

    private func pickTyped(multi: Bool) {
        let t = (typed[page] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if multi { setCursor(cursor + 1); return }      // keep the text (checked if any), on to Next / Submit
        if t.isEmpty { NSSound.beep(); return }
        chosen[page] = []
        advance()
    }

    /// The answer as Claude gets it: picked labels in option order, plus anything typed.
    private func answer(_ i: Int) -> String? {
        guard questions.indices.contains(i) else { return nil }
        let order = (questions[i]["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        let picked = chosen[i] ?? []
        var parts = order.filter(picked.contains)
        let t = (typed[i] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { parts.append(t) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Done with this question: a lone question submits; otherwise on to the next one (or the Submit step).
    private func advance() {
        if questions.count == 1 { submitAnswers(); return }
        goTo(page: page + 1)
    }

    private func goTo(page p: Int) {
        guard prompt?.kind == .question, questions.count > 1 else { return }
        let target = max(0, min(questions.count, p))
        guard target != page else { return }
        page = target
        rebuild()
        window?.makeFirstResponder(self)
    }

    private func refreshTabs() {
        guard questions.count > 1, let strip = stack.arrangedSubviews.first else { return }
        let fresh = tabStrip()
        stack.insertArrangedSubview(fresh, at: 0)
        fresh.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        strip.removeFromSuperview()
    }

    private func submitAnswers() {
        var answers: [String: String] = [:]
        for (i, q) in questions.enumerated() {
            if let a = answer(i) { answers[q["question"] as? String ?? ""] = a }
        }
        guard !answers.isEmpty else { NSSound.beep(); return }
        onAnswer?(.answers(answers))
    }

    private func denyWithFeedback() {
        let msg = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        onAnswer?(.deny(msg.isEmpty ? nil : msg))
    }

    private func dismiss() {
        if let local { local.onCancel(); return }
        if prompt?.kind == .question { onAnswer?(.deny("The user declined to answer.")) } else { denyWithFeedback() }
    }

    // MARK: Cursor and keys

    /// Move the ❯ cursor. Landing on a text row puts the caret in it (`focusField`); leaving one hands the
    /// keys back to the card.
    private func setCursor(_ i: Int, focusField: Bool = true) {
        guard !rows.isEmpty else { return }
        cursor = max(0, min(rows.count - 1, i))
        for (n, r) in rows.enumerated() { r.isCursor = n == cursor }
        if focusField, let f = rows[cursor].field {
            window?.makeFirstResponder(f)
            f.currentEditor()?.selectedRange = NSRange(location: f.stringValue.count, length: 0)
        } else if isEditingField {
            window?.makeFirstResponder(self)
        }
    }

    private var isEditingField: Bool {
        guard let fr = window?.firstResponder as? NSTextView, fr.isFieldEditor else { return false }
        return rows.contains { $0.field != nil && fr.delegate === $0.field }
    }

    private func pick(_ i: Int) {
        guard picks.indices.contains(i) else { return }
        if rows[i].field != nil, !isEditingField { setCursor(i); return }   // walking into the text row
        picks[i]()
    }

    /// ⏎ picks the row — on a multi-select question that toggles it, like space (the Next row moves on).
    private func confirm() {
        guard rows.indices.contains(cursor) else { return }
        pick(cursor)
    }

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 125: setCursor(cursor + 1)                         // ↓
        case 126: setCursor(cursor - 1)                         // ↑
        case 123: goTo(page: page - 1)                          // ←
        case 124: goTo(page: page + 1)                          // →
        case 48:                                                 // tab / ⇧tab: next / previous question
            if prompt?.kind == .question, questions.count > 1 { goTo(page: page + (shift ? -1 : 1)) }
            else { super.keyDown(with: event) }
        case 36, 76: confirm()                                  // return / enter
        case 49: pick(cursor)                                   // space: toggle / pick
        case 53: dismiss()                                      // esc
        case 116: planScroll?.pageUp(nil)
        case 121: planScroll?.pageDown(nil)
        default:
            if let c = event.charactersIgnoringModifiers, let d = Int(c), d >= 1, d <= rows.count {
                setCursor(d - 1)
                if rows[d - 1].field == nil { pick(d - 1) }
                return
            }
            // Typing words: they go to the text row ("Type something…" / "tell Claude what to do instead").
            if event.modifierFlags.intersection([.command, .control]).isEmpty, let chars = event.characters,
               let scalar = chars.unicodeScalars.first, CharacterSet.letters.union(.punctuationCharacters).contains(scalar),
               let i = rows.lastIndex(where: { $0.field != nil }) {
                setCursor(i)
                rows[i].field?.currentEditor()?.insertText(chars)
                return
            }
            super.keyDown(with: event)
        }
    }

    // The text row: ↑/↓ leave it, ⏎ confirms it, esc dismisses the card, tab switches question.
    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, let i = rows.firstIndex(where: { $0.field === f }), i != cursor else { return }
        cursor = i
        for (n, r) in rows.enumerated() { r.isCursor = n == cursor }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        if prompt?.kind == .question {
            typed[page] = f.stringValue
            let has = !f.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
            let multi = questions.indices.contains(page) && questions[page]["multiSelect"] as? Bool == true
            rows.first { $0.field === f }?.mark = multi ? .box(has) : .check(has)
            refreshTabs()
        } else {
            feedbackText = f.stringValue
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): setCursor(cursor - 1); return true
        case #selector(NSResponder.moveDown(_:)): setCursor(cursor + 1); return true
        case #selector(NSResponder.insertNewline(_:)): picks[cursor](); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        case #selector(NSResponder.insertTab(_:)):
            if prompt?.kind == .question, questions.count > 1 { goTo(page: page + 1); return true }
            return false
        case #selector(NSResponder.insertBacktab(_:)):
            if prompt?.kind == .question, questions.count > 1 { goTo(page: page - 1); return true }
            return false
        default: return false
        }
    }

    // MARK: DEV harness

    /// Pick an option by label (on whichever question has it), or nil for the first row / Submit.
    func debugPress(_ label: String?) {
        guard let label else {
            if prompt?.kind == .question { submitAnswers() } else { picks.first?() }
            return
        }
        for (i, q) in questions.enumerated() where (q["options"] as? [[String: Any]] ?? []).contains(where: { $0["label"] as? String == label }) {
            if i != page { page = i; rebuild() }
            if let r = rows.firstIndex(where: { $0.title == label }) { setCursor(r); pick(r) }
            return
        }
    }
    func debugSetFeedback(_ s: String) { feedbackText = s; rows.last?.field?.stringValue = s }
    func debugDeny() { denyWithFeedback() }
    var debugState: [String: Any] {
        ["title": local?.title ?? "", "page": page, "pages": questions.count, "cursor": cursor, "rows": rows.map(\.debugText),
         "editing": isEditingField, "answers": questions.indices.map { answer($0) ?? "" }]
    }
}

/// One numbered choice: `❯ 1. [ ] Label` (a checkbox on multi-select; a single-select pick shows as
/// `Label ✓`) with an optional dim description — or, for the "Type something…" row, a borderless text
/// field in place of the label.
final class ChatChoiceRow: NSView {
    enum Mark { case none, box(Bool), check(Bool) }
    let title: String
    let field: NSTextField?
    var onClick: (() -> Void)?
    var isCursor = false { didSet { if isCursor != oldValue { refresh() } } }
    var mark: Mark { didSet { refreshMark() } }
    private let pointer = NSTextField(labelWithString: "❯")
    private let markView = NSImageView()
    private let titleLabel: NSTextField?

    init(number: Int, title: String, detail: String?, mark: Mark, fieldPlaceholder: String?, fieldText: String, fontSize: CGFloat) {
        self.title = title
        self.mark = mark
        if let fieldPlaceholder {
            let f = NSTextField()
            f.placeholderString = fieldPlaceholder
            f.stringValue = fieldText
            f.isBordered = false
            f.drawsBackground = false
            f.focusRingType = .none
            f.font = .systemFont(ofSize: fontSize)
            f.textColor = ChatStyle.heading
            f.lineBreakMode = .byTruncatingTail
            f.cell?.isScrollable = true
            field = f
            titleLabel = nil
        } else {
            field = nil
            let t = NSTextField(wrappingLabelWithString: title)
            t.font = .systemFont(ofSize: fontSize)
            t.maximumNumberOfLines = 2
            t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleLabel = t
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        pointer.font = .systemFont(ofSize: fontSize, weight: .semibold)
        pointer.textColor = ChatStyle.amber
        let num = NSTextField(labelWithString: number <= 9 ? "\(number)." : "  ")
        num.font = .monospacedDigitSystemFont(ofSize: fontSize - 1, weight: .regular)
        num.textColor = ChatStyle.faint
        num.alignment = .right
        markView.symbolConfiguration = .init(pointSize: fontSize - 1, weight: .regular)
        var content: [NSView] = [titleLabel ?? field!]
        if let detail, !detail.isEmpty {
            let d = NSTextField(wrappingLabelWithString: detail)
            d.font = .systemFont(ofSize: fontSize - 2)
            d.textColor = ChatStyle.dim
            d.maximumNumberOfLines = 2
            d.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            content.append(d)
        }
        let text = NSStackView(views: content)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        var parts: [NSView] = [pointer, num]
        if case .box = mark { parts.append(markView) }
        parts.append(text)
        let h = NSStackView(views: parts)
        h.orientation = .horizontal
        h.alignment = .firstBaseline
        h.spacing = 5
        h.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 8)
        h.translatesAutoresizingMaskIntoConstraints = false
        addSubview(h)
        NSLayoutConstraint.activate([
            h.topAnchor.constraint(equalTo: topAnchor), h.bottomAnchor.constraint(equalTo: bottomAnchor),
            h.leadingAnchor.constraint(equalTo: leadingAnchor), h.trailingAnchor.constraint(equalTo: trailingAnchor),
            pointer.widthAnchor.constraint(equalToConstant: 11),
            num.widthAnchor.constraint(equalToConstant: 17),
            text.trailingAnchor.constraint(lessThanOrEqualTo: h.trailingAnchor, constant: -8),
        ])
        if let field { field.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true }
        refresh()
        refreshMark()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        layer?.backgroundColor = (isCursor ? NSColor(white: 1, alpha: 0.07) : .clear).cgColor
        pointer.alphaValue = isCursor ? 1 : 0
        titleLabel?.textColor = isCursor ? ChatStyle.heading : ChatStyle.text
        if case .check = mark { refreshMark() }     // its attributed title carries the colour
    }

    private func refreshMark() {
        switch mark {
        case .none: markView.image = nil
        case .box(let on):
            markView.image = NSImage(systemSymbolName: on ? "checkmark.square.fill" : "square", accessibilityDescription: on ? "selected" : "not selected")
            markView.contentTintColor = on ? .controlAccentColor : ChatStyle.faint
        case .check(let on):      // after the label, only when picked — no empty slot before it
            guard let t = titleLabel, let font = t.font else { return }
            let s = NSMutableAttributedString(string: title, attributes: [.font: font, .foregroundColor: t.textColor ?? ChatStyle.text])
            if on { s.append(NSAttributedString(string: "  ✓", attributes: [.font: font, .foregroundColor: ChatStyle.green])) }
            t.attributedStringValue = s
        }
    }

    override func mouseDown(with event: NSEvent) { if field == nil { onClick?() } else { super.mouseDown(with: event) } }
    /// A click anywhere on a choice row (its labels included) picks it; a text row keeps its field clickable.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return field == nil && hit != nil ? self : hit
    }
    override func resetCursorRects() { if field == nil { addCursorRect(bounds, cursor: .pointingHand) } }

    var debugText: String {
        let m: String
        switch mark {
        case .none: m = ""
        case .box(let on): m = on ? "[x] " : "[ ] "
        case .check(let on): m = on ? "✓ " : ""
        }
        return (isCursor ? "❯ " : "  ") + m + (field.map { "«\($0.stringValue.isEmpty ? $0.placeholderString ?? "" : $0.stringValue)»" } ?? title)
    }
}

/// A clickable question tab: bright when current, dim otherwise.
final class ChatTabLabel: NSTextField {
    private let action_: () -> Void
    init(_ text: String, current: Bool, size: CGFloat, action: @escaping () -> Void) {
        action_ = action
        super.init(frame: .zero)
        isEditable = false; isBordered = false; drawsBackground = false; isSelectable = false
        stringValue = text
        font = .systemFont(ofSize: size, weight: current ? .semibold : .regular)
        textColor = current ? ChatStyle.heading : ChatStyle.faint
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { action_() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

extension ChatRender {
    /// What a permission prompt is about: the command, the file + diff, the URL…
    static func permissionDetail(_ p: ChatPrompt, style: ChatStyle, cwd: String) -> NSAttributedString {
        var item = ChatItem(id: 0, kind: .tool)
        item.toolName = p.toolName
        item.toolInput = p.input
        item.toolStatus = .done
        let out = NSMutableAttributedString()
        let mono: [NSAttributedString.Key: Any] = [.font: style.mono, .foregroundColor: ChatStyle.text]
        switch p.toolName {
        case "Bash":
            out.append(NSAttributedString(string: p.input["command"] as? String ?? "", attributes: mono))
            if let d = p.input["description"] as? String, !d.isEmpty {
                out.append(NSAttributedString(string: "\n" + d, attributes: [.font: style.small, .foregroundColor: ChatStyle.dim]))
            }
        case "Edit", "MultiEdit", "Write":
            let path = toolSummary(p.toolName, p.input, cwd: cwd)
            out.append(NSAttributedString(string: path, attributes: mono))
            let body = render(item, style: style, cwd: cwd)
            // drop the header line (the tool title) — the card's title already says it
            let s = body.string as NSString
            let nl = s.range(of: "\n")
            if nl.location != NSNotFound, p.toolName != "Write" {
                out.append(NSAttributedString(string: "\n"))
                out.append(body.attributedSubstring(from: NSRange(location: nl.location + 1, length: s.length - nl.location - 1)))
            } else if p.toolName == "Write" {
                let content = (p.input["content"] as? String ?? "").components(separatedBy: "\n")
                out.append(NSAttributedString(string: "\n" + content.prefix(8).joined(separator: "\n") + (content.count > 8 ? "\n… +\(content.count - 8) lines" : ""),
                                              attributes: [.font: style.monoSmall, .foregroundColor: ChatStyle.dim]))
            }
        default:
            let summary = toolSummary(p.toolName, p.input, cwd: cwd)
            if !summary.isEmpty { out.append(NSAttributedString(string: summary, attributes: mono)) }
            else if let data = try? JSONSerialization.data(withJSONObject: p.input, options: [.prettyPrinted, .sortedKeys]),
                    let json = String(data: data, encoding: .utf8) {
                out.append(NSAttributedString(string: String(json.prefix(600)), attributes: [.font: style.monoSmall, .foregroundColor: ChatStyle.dim]))
            }
        }
        return out
    }
}

// MARK: - Activity line (above the input)

/// "✻ Thinking… 12s · ↓ 1.2k tokens · esc to stop" while Claude works; the exit banner (with Restart) when
/// the process has ended; a launch error when `claude` couldn't start.
final class ChatActivityBar: NSView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let restart: ChatActionButton
    private let trust: ChatActionButton
    var onRestart: (() -> Void)?
    var onTrust: (() -> Void)?
    private(set) var textShown = ""

    override init(frame: NSRect) {
        var restartRef: (() -> Void)?, trustRef: (() -> Void)?
        restart = ChatActionButton("Restart", kind: .secondary, size: 11) { restartRef?() }
        trust = ChatActionButton("Trust folder & start", kind: .primary, size: 11) { trustRef?() }
        super.init(frame: frame)
        trust.takesKeyboard = true
        restartRef = { [weak self] in self?.onRestart?() }
        trustRef = { [weak self] in self?.onTrust?() }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 6
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [spinner, label, restart, trust])
        row.orientation = .horizontal
        row.spacing = 7
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Put keyboard focus on "Trust folder & start" (space accepts). False when it isn't showing.
    @discardableResult
    func focusTrust() -> Bool {
        guard !trust.isHidden, let w = window else { return false }
        return w.makeFirstResponder(trust)
    }
    var trustFocused: Bool { window?.firstResponder === trust }

    func update(_ s: ChatSession, fontSize: CGFloat, queueSelection: Int? = nil) {
        var text = ""
        var color: NSColor = ChatStyle.dim
        var spin = false
        var showRestart = false
        var showTrust = false
        switch s.runState {
        case .needsTrust:
            let folder = (s.cwd as NSString).lastPathComponent
            text = "Claude will read, edit and run files in “\(folder)”, and apply its own Claude settings. Chat mode skips Claude’s trust prompt, so confirm you trust this folder."
            if let note = ChatTrust.folderSettingsNote(s.cwd) { text += "\nThis folder has " + note + "." }
            color = ChatStyle.amber
            showTrust = true
        case .failed(let msg):
            text = msg; color = ChatStyle.red
        case .exited(let code, let signaled, let msg):
            let how = signaled ? " (killed by signal \(code))" : code != 0 ? " (exit code \(code))" : ""
            text = "Claude stopped" + how + (msg.isEmpty ? "" : " — " + msg) + ". Restart resumes this conversation."
            color = code == 0 && !signaled ? ChatStyle.dim : ChatStyle.red
            showRestart = true
        case .notStarted:
            text = ""
        case .running:
            if s.prompt != nil {
                text = "Waiting for your answer"; color = ChatStyle.amber
            } else if s.isWorking {
                spin = true
                let secs = s.turnStartedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
                var parts = ["\(s.activity ?? "Working")…", Self.duration(secs)]
                if let est = s.compactEstimate { parts.append("usually about " + Self.duration(est)) }
                if s.thinkingTokens > 0 || s.turnOutputTokens > 0 {
                    parts.append("↓ \(Self.compact(max(s.thinkingTokens, 0) + s.turnOutputTokens)) tokens")
                }
                parts.append("esc to stop")
                text = parts.joined(separator: " · ")
            } else if let note = s.rateLimitNote {
                text = note; color = ChatStyle.red
            }
        }
        let attr = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: fontSize - 1.5), .foregroundColor: color])
        // Sent while busy — Claude runs each after this turn. Three at a time; the window follows the highlight.
        let queued = s.queuedTexts
        let small = NSFont.systemFont(ofSize: fontSize - 1.5)
        func line(_ text: String, _ color: NSColor, bold: Bool = false) {
            attr.append(NSAttributedString(string: (attr.length > 0 ? "\n" : "") + text, attributes: [
                .font: bold ? NSFont.systemFont(ofSize: fontSize - 1.5, weight: .semibold) : small, .foregroundColor: color]))
        }
        if !queued.isEmpty {
            let sel = queueSelection.map { min($0, queued.count - 1) }
            let first = sel.map { max(0, min($0 - 1, queued.count - 3)) } ?? 0
            let shown = first..<min(queued.count, first + 3)
            if shown.lowerBound > 0 { line("↳ \(shown.lowerBound) more above", ChatStyle.faint) }
            for i in shown {
                let one = queued[i].replacingOccurrences(of: "\n", with: " ")
                let text = one.count > 120 ? String(one.prefix(119)) + "…" : one
                if i == sel { line("❯ queued: " + text, NSColor(white: 0.92, alpha: 1), bold: true) }
                else { line("↳ queued: " + text, ChatStyle.faint) }
            }
            if shown.upperBound < queued.count { line("↳ +\(queued.count - shown.upperBound) more queued", ChatStyle.faint) }
            line(sel == nil ? "↑ to edit a queued message" : "⏎ edit · ↑↓ choose · esc cancel", ChatStyle.faint)
        }
        label.attributedStringValue = attr
        text = attr.string
        textShown = text
        if spin { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        restart.isHidden = !showRestart
        trust.isHidden = !showTrust
    }

    static func duration(_ s: Int) -> String { s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s" }
    static func compact(_ n: Int) -> String { n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)" }
}

// MARK: - Footer (the status line)

/// The terminal status line, native: permission mode (click / ⇧⇥ to cycle) on the left; folder · branch ·
/// model ▾ · context % · 5h and 7d usage · background tasks · cost · Open in Terminal on the right.
/// Items hide right-to-left by priority when the pane is narrow.
final class ChatFooterView: NSView {
    var onCycleMode: (() -> Void)?
    var onPickMode: ((String) -> Void)?
    var onPickModel: ((String) -> Void)?
    var onContext: ((NSView) -> Void)?
    var onTasks: (() -> Void)?
    var onOpenTerminal: (() -> Void)?
    var onPickEffort: ((String) -> Void)?
    var onFastMode: ((Bool) -> Void)?
    var onOtherModel: (() -> Void)?
    var onResume: (() -> Void)?
    var onRemote: ((Bool) -> Void)?             // turn Remote Control on / off

    private let modeButton = PointerButton()
    private let folder = NSTextField(labelWithString: "")
    private let branch = NSTextField(labelWithString: "")
    private let modelButton = PointerButton()
    private let ctxButton = PointerButton()
    private let fiveHour = NSTextField(labelWithString: "")
    private let sevenDay = NSTextField(labelWithString: "")
    private let tasksButton = PointerButton()
    private let cost = NSTextField(labelWithString: "")
    private let terminalButton = HoverIconButton()
    private let resumeButton = HoverIconButton()
    private let remoteButton = HoverIconButton()
    private let right = NSStackView()
    private var modeWidth: NSLayoutConstraint!
    private var models: [ChatModelOption] = []
    private var modes: [String] = []
    private var currentMode = "default"
    private var currentModel: String?
    private var currentEffort: String?
    private var fastState: String?
    private var fastReason: String?
    private var remoteURL: String?
    private var fontSize: CGFloat = 12
    private var ctxMeter: (Int, CGFloat) = (-2, 0)     // what the context bar image shows (-1 = not measured)
    private(set) var snapshot: [String: String] = [:]   // DEV: what each item shows

    override init(frame: NSRect) {
        super.init(frame: frame)
        for b in [modeButton, modelButton, ctxButton, tasksButton] {
            b.cell?.wraps = false
            b.cell?.lineBreakMode = .byClipping
            b.isBordered = false
            b.bezelStyle = .inline
            b.setButtonType(.momentaryChange)
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        modeButton.target = self; modeButton.action = #selector(modeTapped)
        modeButton.toolTip = "Permission mode — click or ⇧⇥ to cycle"
        modelButton.target = self; modelButton.action = #selector(modelTapped)
        modelButton.toolTip = "Switch model"
        ctxButton.target = self; ctxButton.action = #selector(ctxTapped)
        ctxButton.imagePosition = .imageRight
        tasksButton.target = self; tasksButton.action = #selector(tasksTapped)
        tasksButton.toolTip = "Background tasks Claude started"
        terminalButton.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Open in Terminal")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        terminalButton.isBordered = false
        terminalButton.bezelStyle = .inline
        terminalButton.toolTip = "Continue this conversation in a terminal tab (Claude’s full terminal UI)"
        terminalButton.target = self; terminalButton.action = #selector(terminalTapped)
        for (b, symbol, tip, sel) in [(resumeButton, "clock.arrow.circlepath", "Resume a past conversation in this chat (/resume)", #selector(resumeTapped)),
                                      (remoteButton, "antenna.radiowaves.left.and.right", "Remote Control — continue this session from claude.ai or the Claude app", #selector(remoteTapped))] {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            b.isBordered = false
            b.bezelStyle = .inline
            b.toolTip = tip
            b.target = self; b.action = sel
            b.baseTint = NSColor(white: 0.55, alpha: 1)
        }
        for l in [folder, branch, fiveHour, sevenDay, cost] {
            l.lineBreakMode = .byTruncatingTail
            l.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }
        for b in [modelButton, ctxButton, tasksButton] { b.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal) }

        let items: [NSView] = [folder, branch, modelButton, ctxButton, fiveHour, sevenDay, tasksButton, cost, remoteButton, resumeButton, terminalButton]
        items.forEach { right.addArrangedSubview($0) }
        right.orientation = .horizontal
        right.spacing = 12
        right.alignment = .centerY
        right.detachesHiddenViews = true
        // Narrow pane → drop the least important first.
        let prio: [(NSView, Float)] = [(cost, 100), (folder, 200), (branch, 250), (sevenDay, 300), (fiveHour, 400),
                                       (tasksButton, 700), (modelButton, 800), (ctxButton, 900), (resumeButton, 950),
                                       (remoteButton, 960), (terminalButton, 1000)]
        for (v, p) in prio { right.setVisibilityPriority(NSStackView.VisibilityPriority(p), for: v) }
        right.setClippingResistancePriority(.defaultLow, for: .horizontal)
        right.translatesAutoresizingMaskIntoConstraints = false
        modeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(modeButton)
        addSubview(right)
        // An explicit width: the button's own intrinsic size lags its attributed title here, and a stale
        // (too small) width wrapped/clipped the label.
        modeWidth = modeButton.widthAnchor.constraint(equalToConstant: 120)
        NSLayoutConstraint.activate([
            modeWidth,
            modeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            modeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: modeButton.trailingAnchor, constant: 16),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func modeLabel(_ m: String) -> (String, NSColor) {
        switch m {
        case "acceptEdits": return ("⏵⏵ accept edits on", NSColor(srgbRed: 0.72, green: 0.56, blue: 0.98, alpha: 1))
        case "plan": return ("⏸ plan mode on", NSColor(srgbRed: 0.35, green: 0.78, blue: 0.78, alpha: 1))
        case "auto": return ("⏵⏵ auto mode on", NSColor(srgbRed: 0.45, green: 0.75, blue: 0.95, alpha: 1))
        case "bypassPermissions": return ("⏵⏵ bypass permissions on", ChatStyle.red)
        case "dontAsk": return ("don’t ask", ChatStyle.amber)
        default: return ("? ask before edits", NSColor(white: 0.5, alpha: 1))
        }
    }

    private func set(_ b: NSButton, _ s: String, _ c: NSColor) {
        b.attributedTitle = NSAttributedString(string: s, attributes: [.foregroundColor: c, .font: NSFont.systemFont(ofSize: fontSize)])
    }
    private func set(_ l: NSTextField, _ s: String, _ c: NSColor) {
        l.stringValue = s; l.textColor = c; l.font = .systemFont(ofSize: fontSize)
        l.isHidden = s.isEmpty
    }

    static func usageColor(_ pct: Int) -> NSColor {
        pct >= 85 ? ChatStyle.red : pct >= 60 ? ChatStyle.amber : NSColor(white: 0.6, alpha: 1)
    }

    /// The context meter: a short bar filled to `pct` (nil = not measured yet — empty track).
    static func contextBar(_ pct: Int?, fontSize: CGFloat) -> NSImage {
        let size = NSSize(width: (fontSize * 4).rounded(), height: (fontSize * 0.5).rounded())
        return NSImage(size: size, flipped: false) { r in
            let radius = r.height / 2
            NSColor(white: 1, alpha: 0.12).setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            guard let pct, pct > 0 else { return true }
            let fill = NSRect(x: 0, y: 0, width: max(r.height, r.width * CGFloat(pct) / 100), height: r.height)
            contextColor(pct).setFill()
            NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
            return true
        }
    }

    /// Deep blue while there's room, lightening toward the middle, then yellow → orange → red as it fills. Blue
    /// and yellow are opposites — a straight blend goes grey-green — so the hand-off passes through a bright pale step.
    static func contextColor(_ pct: Int) -> NSColor {
        let stops: [(Double, (Double, Double, Double))] = [
            (0, (0.24, 0.44, 0.95)), (45, (0.45, 0.74, 1.0)), (53, (0.84, 0.88, 0.86)),
            (62, (0.97, 0.84, 0.32)), (80, (0.98, 0.58, 0.22)), (100, (0.94, 0.30, 0.30)),
        ]
        let p = Double(min(100, max(0, pct)))
        let hi = stops.firstIndex { $0.0 >= p } ?? stops.count - 1
        let lo = max(0, hi - 1)
        let t = stops[hi].0 == stops[lo].0 ? 0 : (p - stops[lo].0) / (stops[hi].0 - stops[lo].0)
        let (a, b) = (stops[lo].1, stops[hi].1)
        return NSColor(srgbRed: a.0 + (b.0 - a.0) * t, green: a.1 + (b.1 - a.1) * t, blue: a.2 + (b.2 - a.2) * t, alpha: 1)
    }

    /// "23m" / "4h12m" / "1d22h" until `date`.
    static func until(_ date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSinceNow))
        if s >= 86_400 { return "\(s / 86_400)d\((s % 86_400) / 3600)h" }
        if s >= 3600 { return "\(s / 3600)h\((s % 3600) / 60)m" }
        return "\(max(1, s / 60))m"
    }

    func update(_ s: ChatSession, branch br: String?, fontSize: CGFloat) {
        self.fontSize = fontSize
        models = s.models
        modes = s.modeCycle
        currentMode = s.permissionMode
        currentModel = s.model
        currentEffort = s.effort
        fastState = s.fastModeState
        fastReason = s.fastModeReason
        remoteURL = s.remoteURL
        let dim = NSColor(white: 0.6, alpha: 1)
        let (mode, modeColor) = Self.modeLabel(s.permissionMode)
        set(modeButton, mode + "  (⇧⇥)", modeColor)
        modeWidth.constant = ceil(modeButton.attributedTitle.size().width) + 6
        set(folder, (s.cwd as NSString).lastPathComponent, dim)
        set(branch, br.map { "⎇ " + $0 } ?? "", dim)
        let modelName = s.model.map(ModelName.display) ?? "…"
        let effortShown = s.currentModelOption?.effortLevels.isEmpty == false ? s.effort : nil   // Haiku: no effort
        let extras = [effortShown, s.fastModeState == "on" ? "fast" : nil].compactMap { $0 }
        set(modelButton, modelName + (extras.isEmpty ? "" : " · " + extras.joined(separator: " · ")) + " ▾", NSColor(white: 0.78, alpha: 1))
        let pct = s.contextPercent
        set(ctxButton, "ctx", dim)
        let meter = (s.contextUsed > 0 ? pct : -1, fontSize)
        if meter != ctxMeter {      // this runs on every chat update — redraw the bar only when it changes
            ctxMeter = meter
            ctxButton.image = Self.contextBar(s.contextUsed > 0 ? pct : nil, fontSize: fontSize)
        }
        ctxButton.toolTip = (s.contextUsed > 0 ? "Context \(pct)% used" : "Context not measured yet") + " — click for a breakdown"
        ctxButton.setAccessibilityValue(s.contextUsed > 0 ? "\(pct)%" : nil)
        if let w = s.fiveHour {
            let p = Int((w.utilization * 100).rounded())
            set(fiveHour, "5h \(p)% ·\(Self.until(w.resetsAt))", Self.usageColor(p))
        } else { set(fiveHour, "", dim) }
        if let w = s.sevenDay {
            let p = Int((w.utilization * 100).rounded())
            set(sevenDay, "7d \(p)% ·\(Self.until(w.resetsAt))", Self.usageColor(p))
        } else { set(sevenDay, "", dim) }
        let running = s.tasks.filter(\.isRunning)
        let agents = running.filter { $0.type == "local_agent" }.count
        let shells = running.count - agents
        var t: [String] = []
        if shells > 0 { t.append("\(shells) shell\(shells == 1 ? "" : "s")") }
        if agents > 0 { t.append("\(agents) agent\(agents == 1 ? "" : "s")") }
        let ports = running.flatMap(\.ports)
        if !ports.isEmpty { t.append(ports.prefix(3).map { ":\($0)" }.joined(separator: " ")) }
        tasksButton.isHidden = s.tasks.isEmpty
        set(tasksButton, "⚙ " + (t.isEmpty ? "\(s.tasks.count) done" : t.joined(separator: " · ")),
            running.isEmpty ? dim : NSColor(srgbRed: 0.45, green: 0.75, blue: 0.95, alpha: 1))
        set(cost, s.totalCostUSD > 0 ? String(format: "$%.2f", s.totalCostUSD) : "", NSColor(white: 0.45, alpha: 1))
        terminalButton.baseTint = NSColor(white: 0.55, alpha: 1)
        remoteButton.baseTint = s.remoteURL != nil ? ChatStyle.green : NSColor(white: 0.55, alpha: 1)
        remoteButton.toolTip = s.remoteURL.map { "Remote Control is on — \($0)" }
            ?? "Remote Control — continue this session from claude.ai or the Claude app"
        snapshot = ["mode": modeButton.title, "folder": folder.stringValue, "branch": branch.stringValue,
                    "model": modelButton.title, "ctx": s.contextUsed > 0 ? "\(pct)%" : "—", "5h": fiveHour.stringValue,
                    "7d": sevenDay.stringValue, "tasks": tasksButton.isHidden ? "" : tasksButton.title,
                    "cost": cost.stringValue, "remote": s.remoteURL ?? ""]
    }

    @objc private func modeTapped() {
        let menu = NSMenu()
        for m in modes {
            let item = NSMenuItem(title: Self.modeLabel(m).0, action: #selector(modePicked(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = m
            item.state = m == currentMode ? .on : .off
            if m == "bypassPermissions" { item.toolTip = "Claude runs every tool without asking" }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let cycle = NSMenuItem(title: "Cycle (⇧⇥)", action: #selector(cycleTapped), keyEquivalent: "")
        cycle.target = self
        menu.addItem(cycle)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: modeButton.bounds.height + 2), in: modeButton)
    }
    @objc private func modePicked(_ i: NSMenuItem) { if let m = i.representedObject as? String { onPickMode?(m) } }
    @objc private func cycleTapped() { onCycleMode?() }

    func showModelMenu() { modelTapped() }

    /// The terminal UI's `/model` picker: the models, then effort for the picked model, fast mode, and any
    /// other model by name.
    @objc private func modelTapped() {
        let menu = NSMenu()
        let current = models.first { $0.resolved == currentModel } ?? models.first { $0.value == currentModel }
        for m in models {
            let item = NSMenuItem(title: m.displayName, action: #selector(modelPicked(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = m.value
            item.toolTip = m.description
            item.state = m.value == current?.value ? .on : .off
            menu.addItem(item)
        }
        if menu.items.isEmpty { menu.addItem(withTitle: "Models load after Claude starts", action: nil, keyEquivalent: "") }
        let other = NSMenuItem(title: "Other model…", action: #selector(otherModelTapped), keyEquivalent: "")
        other.target = self
        other.toolTip = "Any model id or alias, e.g. claude-opus-4-8 or sonnet[1m]"
        menu.addItem(other)

        menu.addItem(.separator())
        if let levels = current?.effortLevels, !levels.isEmpty {
            menu.addItem(Self.header("Effort" + (currentEffort == nil ? " (model default)" : "")))
            for l in levels {
                let item = NSMenuItem(title: l.prefix(1).uppercased() + String(l.dropFirst()), action: #selector(effortPicked(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = l
                item.state = l == currentEffort ? .on : .off
                item.indentationLevel = 1
                menu.addItem(item)
            }
        } else {
            menu.addItem(Self.header("Effort not supported for this model"))
        }
        if current?.supportsFastMode == true {
            menu.addItem(.separator())
            let on = fastState == "on"
            let fast = NSMenuItem(title: "Fast mode", action: #selector(fastTapped), keyEquivalent: "")
            fast.target = self
            fast.state = on ? .on : .off
            if !on, let reason = fastReason, reason != "sdk_opt_in_required" {
                fast.title = "Fast mode — unavailable (\(reason.replacingOccurrences(of: "_", with: " ")))"
                fast.action = nil
            }
            menu.addItem(fast)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: modelButton.bounds.height + 2), in: modelButton)
    }

    private static func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func modelPicked(_ i: NSMenuItem) { if let v = i.representedObject as? String { onPickModel?(v) } }
    @objc private func effortPicked(_ i: NSMenuItem) { if let v = i.representedObject as? String { onPickEffort?(v) } }
    @objc private func fastTapped() { onFastMode?(fastState != "on") }
    @objc private func otherModelTapped() { onOtherModel?() }
    @objc private func resumeTapped() { onResume?() }

    @objc private func remoteTapped() {
        guard let url = remoteURL else { onRemote?(true); return }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Session in Browser", action: #selector(remoteOpen), keyEquivalent: "")
        let copy = NSMenuItem(title: "Copy Session Link", action: #selector(remoteCopy), keyEquivalent: "")
        let stop = NSMenuItem(title: "Stop Remote Control", action: #selector(remoteStop), keyEquivalent: "")
        for i in [open, copy, stop] { i.target = self }
        menu.addItem(Self.header(url))
        menu.addItem(.separator())
        [open, copy, stop].forEach(menu.addItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: remoteButton.bounds.height + 2), in: remoteButton)
    }
    @objc private func remoteOpen() { if let u = remoteURL.flatMap(URL.init(string:)) { NSWorkspace.shared.open(u) } }
    @objc private func remoteCopy() { if let u = remoteURL { Clipboard.copy(u) } }
    @objc private func remoteStop() { onRemote?(false) }
    @objc private func ctxTapped() { onContext?(ctxButton) }
    @objc private func tasksTapped() { onTasks?() }
    @objc private func terminalTapped() { onOpenTerminal?() }
}

// MARK: - Background tasks panel

/// Claude's background tasks — servers, watchers, async subagents — with live status, elapsed time, the
/// ports a server is listening on (click to open), its log (tailed live), and Stop.
final class ChatTasksPanel: NSView {
    var onStop: ((String) -> Void)?
    var onClearFinished: (() -> Void)?
    var onClose: (() -> Void)?
    private let header = NSTextField(labelWithString: "")
    private let rowsStack = NSStackView()
    private let logView = NSTextView()
    private let logScroll = NSScrollView()
    private var logHeight: NSLayoutConstraint!
    private(set) var logTaskID: String?
    private var fontSize: CGFloat = 12
    private var lastTasks: [ChatTask] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0.25, alpha: 1).cgColor

        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = NSColor(white: 0.6, alpha: 1)
        let clear = ChatActionButton("Clear finished", kind: .secondary, size: 10.5) { [weak self] in self?.onClearFinished?() }
        let close = ClosureButton(symbol: "xmark", pointSize: 10) { [weak self] in self?.onClose?() }
        close.toolTip = "Hide"
        let top = NSStackView(views: [header, NSView(), clear, close])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 8

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 2

        logView.isEditable = false
        logView.drawsBackground = true
        logView.backgroundColor = NSColor(white: 0.09, alpha: 1)
        logView.textColor = NSColor(white: 0.78, alpha: 1)
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textContainerInset = NSSize(width: 6, height: 6)
        logView.autoresizingMask = [.width]
        logView.isVerticallyResizable = true
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.autohidesScrollers = true
        logScroll.drawsBackground = false
        logScroll.wantsLayer = true
        logScroll.layer?.cornerRadius = 6

        let v = NSStackView(views: [top, rowsStack, logScroll])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 6
        v.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 10, right: 10)
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        logHeight = logScroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor),
            v.bottomAnchor.constraint(equalTo: bottomAnchor),
            v.leadingAnchor.constraint(equalTo: leadingAnchor),
            v.trailingAnchor.constraint(equalTo: trailingAnchor),
            top.widthAnchor.constraint(equalTo: v.widthAnchor, constant: -22),
            rowsStack.widthAnchor.constraint(equalTo: v.widthAnchor, constant: -22),
            logScroll.widthAnchor.constraint(equalTo: v.widthAnchor, constant: -22),
            logHeight,
        ])
        logScroll.isHidden = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func update(_ tasks: [ChatTask], fontSize: CGFloat) {
        self.fontSize = fontSize
        let running = tasks.filter(\.isRunning).count
        header.stringValue = "BACKGROUND TASKS · \(running) running" + (tasks.count > running ? " · \(tasks.count - running) finished" : "")
        lastTasks = tasks
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if tasks.isEmpty {
            let l = NSTextField(labelWithString: "Nothing running. When Claude starts a server, watcher or background agent, it shows up here.")
            l.font = .systemFont(ofSize: fontSize - 1.5)
            l.textColor = ChatStyle.faint
            rowsStack.addArrangedSubview(l)
        }
        for t in tasks.suffix(12) { rowsStack.addArrangedSubview(taskRow(t)) }
        if let id = logTaskID, !tasks.contains(where: { $0.id == id }) { showLog(nil) }
        refreshLog()
    }

    private func taskRow(_ t: ChatTask) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = (t.isRunning ? ChatStyle.green : t.status == "failed" ? ChatStyle.red : ChatStyle.faint).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 7).isActive = true

        let kind = t.type == "local_agent" ? "Agent" : t.isShell ? "Shell" : (t.type.isEmpty ? "Task" : t.type)
        let name = NSTextField(labelWithString: "\(kind) · \(t.description.isEmpty ? t.id : t.description)")
        name.font = t.isShell ? .monospacedSystemFont(ofSize: fontSize - 1.5, weight: .regular) : .systemFont(ofSize: fontSize - 1)
        name.textColor = t.isRunning ? NSColor(white: 0.88, alpha: 1) : ChatStyle.dim
        name.lineBreakMode = .byTruncatingTail
        name.toolTip = t.description
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let elapsed = Int((t.endedAt ?? Date()).timeIntervalSince(t.startedAt))
        var statusText = t.isRunning ? "running \(ChatActivityBar.duration(elapsed))" : t.status
        if let a = t.activity, t.isRunning, t.type == "local_agent" { statusText += " · " + a }
        let status = NSTextField(labelWithString: statusText)
        status.font = .systemFont(ofSize: fontSize - 2)
        status.textColor = ChatStyle.faint
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)

        var views: [NSView] = [dot, name, status]
        for p in t.ports {
            let chip = ChatActionButton(":\(p) ↗", kind: .secondary, size: fontSize - 2.5) {
                if let url = URL(string: "http://localhost:\(p)") { NSWorkspace.shared.open(url) }
            }
            chip.toolTip = "Open http://localhost:\(p)"
            views.append(chip)
        }
        views.append(NSView())
        if t.outputFile != nil {
            let log = ClosureButton(symbol: t.id == logTaskID ? "doc.text.fill" : "doc.text", pointSize: 11) { [weak self] in
                self?.showLog(self?.logTaskID == t.id ? nil : t.id)
            }
            log.toolTip = "Show output"
            views.append(log)
        }
        if t.isRunning {
            let stop = ClosureButton(symbol: "stop.circle", pointSize: 12) { [weak self] in self?.onStop?(t.id) }
            stop.contentTintColor = ChatStyle.red
            stop.toolTip = "Stop this task"
            views.append(stop)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        return row
    }

    func showLog(_ id: String?) {
        logTaskID = id
        logScroll.isHidden = id == nil
        logHeight.constant = id == nil ? 0 : 150
        update(lastTasks, fontSize: fontSize)
    }

    /// Tail the selected task's output file (last 64 KB), sticking to the bottom.
    func refreshLog() {
        guard let id = logTaskID, let t = lastTasks.first(where: { $0.id == id }), let path = t.outputFile else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var text = "(no output yet)"
            if let h = FileHandle(forReadingAtPath: path) {
                let size = (try? h.seekToEnd()) ?? 0
                try? h.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
                if let d = try? h.readToEnd(), !d.isEmpty { text = ChatHistory.stripANSI(String(decoding: d, as: UTF8.self)) }
                try? h.close()
            }
            DispatchQueue.main.async {
                guard let self, self.logTaskID == id, self.logView.string != text else { return }
                let atBottom = self.logScroll.contentView.bounds.maxY >= (self.logView.frame.height - 20)
                self.logView.string = text
                if atBottom { self.logView.scrollToEndOfDocument(nil) }
            }
        }
    }

    var logText: String { logView.string }
}

// MARK: - Side question (/btw)

/// `/btw`: a quick question Claude answers from the conversation's context without adding either to it.
/// The answer shows here as Markdown (scrolling past ~320pt); esc or × dismisses it.
final class ChatSidePanel: NSView {
    var onClose: (() -> Void)?
    private let questionLabel = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private let answerView = NSTextView()
    private var answerHeight: NSLayoutConstraint!
    private var shown = NSAttributedString()
    private(set) var question = "", answer = ""        // what's on the card (DEV harness reads these)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor(white: 0.155, alpha: 1).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0.3, alpha: 1).cgColor
        let title = NSTextField(labelWithString: "Side question")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = ChatStyle.heading
        let note = NSTextField(labelWithString: "not added to the conversation · esc to dismiss")
        note.font = .systemFont(ofSize: 11)
        note.textColor = ChatStyle.faint
        let close = ClosureButton(symbol: "xmark", pointSize: 10) { [weak self] in self?.onClose?() }
        close.toolTip = "Dismiss (esc)"
        let top = NSStackView(views: [title, note, NSView(), close])
        top.orientation = .horizontal
        top.spacing = 8
        questionLabel.font = .systemFont(ofSize: 12)
        questionLabel.textColor = ChatStyle.dim
        questionLabel.maximumNumberOfLines = 3
        questionLabel.isSelectable = true
        answerView.isEditable = false
        answerView.isSelectable = true
        answerView.drawsBackground = false
        answerView.textContainerInset = NSSize(width: 0, height: 4)
        answerView.textContainer?.lineFragmentPadding = 0      // line up with the question above
        answerView.autoresizingMask = [.width]
        answerView.isVerticallyResizable = true
        scroll.documentView = answerView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let v = NSStackView(views: [top, questionLabel, scroll])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 6
        v.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        answerHeight = scroll.heightAnchor.constraint(equalToConstant: 24)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
            v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
            top.widthAnchor.constraint(equalTo: v.widthAnchor, constant: -28),
            questionLabel.widthAnchor.constraint(equalTo: v.widthAnchor, constant: -28),
            scroll.widthAnchor.constraint(equalTo: v.widthAnchor, constant: -28),
            answerHeight,
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// A new question, waiting for its answer.
    func ask(_ q: String, style: ChatStyle) {
        question = q
        answer = ""
        questionLabel.stringValue = q
        set(NSAttributedString(string: "Thinking…", attributes: [.font: ChatStyle.trait(style.small, .italic), .foregroundColor: ChatStyle.faint]))
    }

    func setAnswer(_ markdown: String, style: ChatStyle) {
        answer = markdown
        set(ChatMarkdown.render(markdown, style: style))
    }

    func setError(_ text: String, style: ChatStyle) {
        answer = text
        set(NSAttributedString(string: text, attributes: [.font: style.small, .foregroundColor: ChatStyle.red]))
    }

    private func set(_ s: NSAttributedString) {
        shown = s
        answerView.textStorage?.setAttributedString(s)
        answerView.scroll(.zero)
        fitHeight()
    }

    override func layout() {
        super.layout()
        fitHeight()
    }

    /// The answer's full height, up to 320pt (then it scrolls). Re-measured when the width changes.
    private func fitHeight() {
        let width = scroll.bounds.width > 20 ? scroll.bounds.width : max(300, (superview?.bounds.width ?? 700) - 28)
        let h = min(320, max(22, ChatMeasurer().height(shown, width: width) + 10))
        if abs(answerHeight.constant - h) > 0.5 { answerHeight.constant = h }
    }
}
