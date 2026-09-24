import AppKit
import UniformTypeIdentifiers

/// The message box: a growing multi-line text view (1–10 lines) with the terminal UI's keys — ⏎ sends,
/// ⇧⏎/⌥⏎ newline, esc stops Claude, ⇧⇥ cycles the permission mode, `!` runs a shell command, ↑ on an empty box recalls the last
/// message — plus inline completion for `/commands` and `@files`.
final class ChatInputView: NSView, NSTextViewDelegate {
    var onSend: ((String, [ChatAttachment]) -> Void)?
    var onEscape: (() -> Void)?
    var onCycleMode: (() -> Void)?
    /// Messages sent while Claude works wait in its queue; ↑ walks them (newest first) instead of history, ⏎
    /// takes the highlighted one back to edit, esc leaves — the terminal UI's "select a queued message".
    var queuedCount: () -> Int = { 0 }
    var onQueueSelection: ((Int?) -> Void)?
    var onEditQueued: ((Int) -> Void)?
    private(set) var queueSelection: Int? {
        didSet { if queueSelection != oldValue { onQueueSelection?(queueSelection) } }
    }
    private var lastQueuedCount = 0
    var onStop: (() -> Void)?
    /// Completion sources, pulled on demand.
    var commands: () -> [ChatCommand] = { [] }
    var files: () -> [String] = { [] }

    private let box = NSView()
    private let scroll = NSScrollView()
    let textView = ChatInputTextView()
    private static let placeholderText = "Message Claude…   / commands · @ files · ! shell"
    private let placeholder = NSTextField(labelWithString: placeholderText)
    private let sendButton = PointerButton()
    private let micButton = PointerButton()
    /// Voice input (fn⌃ or the mic): the words land at the caret as they're heard and are sent only on ⏎.
    let voice = ChatVoice()
    var onVoiceError: ((String) -> Void)?
    var onPreviewImages: (([URL], Int) -> Void)?    // a thumbnail clicked → the box's images, which one
    private let strip = ChatAttachmentStrip()
    private var stripHeight: NSLayoutConstraint!
    /// Where the spoken text sits in the box — replaced whole on each update (the service re-sends the
    /// utterance so far). nil once the box moved on (sent, cleared, or an edit ran into it).
    private var voiceSpan: NSRange?
    private var voiceLead = ""              // a space in front when the caret followed a word
    private var applyingVoice = false
    private var voiceOriginal = ""          // what the spoken words replaced (the selection when it started)
    /// While words are streaming in, the box has no undo: they are edited in outside it, so earlier undo steps
    /// would point at the wrong characters. When it ends they're put back as one ordinary edit — one ⌘Z.
    var dictating: Bool { voiceSpan != nil }
    private var sendAfterVoice = false      // ⏎ while the last words are still coming: send when they land
    private var heightConstraint: NSLayoutConstraint!
    private let completion = ChatCompletionView()
    private var completionHeight: NSLayoutConstraint!
    private var history: [String] = []
    private var historyIndex: Int?
    private var fontSize: CGFloat = 13
    /// Images pasted into this message, shown as thumbnails above the text (numbered by position). They go
    /// to Claude as image blocks ahead of the text, which is plain — no markers in it.
    private(set) var attachments: [ChatAttachment] = [] { didSet { attachmentsChanged() } }
    var working = false { didSet { updateButton() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor(white: 0.28, alpha: 1).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)

        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textColor = NSColor(white: 0.92, alpha: 1)
        textView.insertionPointColor = NSColor(white: 0.92, alpha: 1)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.delegate = self
        textView.owner = self
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scroll)

        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.onRemove = { [weak self] i in self?.removeAttachment(i) }
        strip.onPreview = { [weak self] i in self?.previewAttachment(i) }
        box.addSubview(strip)

        placeholder.textColor = NSColor(white: 0.45, alpha: 1)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(placeholder)

        sendButton.isBordered = false
        sendButton.bezelStyle = .inline
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(sendButton)

        micButton.isBordered = false
        micButton.bezelStyle = .inline
        micButton.target = self
        micButton.action = #selector(micTapped)
        micButton.wantsLayer = true
        micButton.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(micButton)
        voice.onText = { [weak self] t in self?.voiceText(t) }
        voice.onState = { [weak self] st in self?.voiceState(st) }
        voice.onError = { [weak self] m in self?.onVoiceError?(m) }

        completion.isHidden = true
        completion.translatesAutoresizingMaskIntoConstraints = false
        completion.onPick = { [weak self] i in self?.acceptCompletion(i) }
        addSubview(completion)

        heightConstraint = scroll.heightAnchor.constraint(equalToConstant: 20)
        stripHeight = strip.heightAnchor.constraint(equalToConstant: 0)
        completionHeight = completion.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            completion.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            completion.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            completion.bottomAnchor.constraint(equalTo: box.topAnchor, constant: -4),
            completion.topAnchor.constraint(equalTo: topAnchor),
            completionHeight,
            box.topAnchor.constraint(equalTo: completion.bottomAnchor, constant: 4),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.topAnchor.constraint(equalTo: box.topAnchor, constant: 9),
            strip.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            strip.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            stripHeight,
            scroll.topAnchor.constraint(equalTo: strip.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -9),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: micButton.leadingAnchor, constant: -6),
            heightConstraint,
            placeholder.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            placeholder.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 2),
            sendButton.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            sendButton.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -7),
            sendButton.widthAnchor.constraint(equalToConstant: 24),
            sendButton.heightAnchor.constraint(equalToConstant: 24),
            micButton.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -2),
            micButton.bottomAnchor.constraint(equalTo: sendButton.bottomAnchor),
            micButton.widthAnchor.constraint(equalToConstant: 24),
            micButton.heightAnchor.constraint(equalToConstant: 24),
        ])
        setFontSize(13)
        updateButton()
        updateMic()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setFontSize(_ size: CGFloat) {
        fontSize = size
        textView.font = .systemFont(ofSize: size)
        placeholder.font = .systemFont(ofSize: size)
        completion.fontSize = size
        resize()
    }

    func focus() { window?.makeFirstResponder(textView) }
    var textViewForFocus: NSResponder { textView }

    var text: String {
        get { textView.string }
        set { dropVoiceSpan(); textView.string = newValue; textChanged() }
    }

    /// A queued message taken back to edit: its text goes above whatever is typed, its images ahead of the box's.
    func restore(_ text: String, images: [ChatAttachment]) {
        let t = text
        dropVoiceSpan()
        let draft = textView.string
        textView.string = draft.isEmpty ? t : t + "\n" + draft
        attachments = images + attachments
        historyIndex = nil
        textView.setSelectedRange(NSRange(location: (t as NSString).length, length: 0))
        textChanged()
        focus()
    }

    /// The queue moved on (a message started, or one was taken back): a highlight by position would now point
    /// at a different message, so drop it.
    func queueChanged() {
        let n = queuedCount()
        if n != lastQueuedCount { lastQueuedCount = n; queueSelection = nil }
    }

    /// esc esc with something typed: throw the draft away, images and all — what the terminal UI does.
    func clear() {
        dropVoiceSpan()
        textView.string = ""
        attachments = []
        historyIndex = nil
        textChanged()
    }

    /// Nothing typed and no images — esc esc then offers /rewind instead of clearing.
    var isDraftEmpty: Bool { textView.string.isEmpty && attachments.isEmpty }

    private var hasContent: Bool {
        !attachments.isEmpty || !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A key typed while a transcript row had focus: focus the box and replay the key here.
    func typeAhead(_ event: NSEvent) {
        focus()
        textView.keyDown(with: event)
    }

    private func updateButton() {
        let empty = !hasContent
        let stop = working && empty
        sendButton.image = NSImage(systemSymbolName: stop ? "stop.circle.fill" : "arrow.up.circle.fill",
                                   accessibilityDescription: stop ? "Stop" : "Send")?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        sendButton.contentTintColor = stop ? ChatStyle.red : (empty ? NSColor(white: 0.4, alpha: 1) : NSColor.controlAccentColor)
        sendButton.toolTip = stop ? "Stop Claude (esc)" : "Send (⏎)"
    }

    @objc private func sendTapped() {
        if working, !hasContent { onStop?(); return }
        submit()
    }

    func submit() {
        // Still listening (or the last words are on their way): stop, and send once they're in the box.
        if voice.state != .idle { sendAfterVoice = true; voice.stop(); return }
        guard hasContent else { return }
        let t = textView.string
        let images = attachments
        if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { history.append(t) }
        historyIndex = nil
        dropVoiceSpan()
        textView.string = ""
        attachments = []
        textChanged()
        onSend?(t, images)
    }

    /// Paste or drop: every image on the pasteboard joins this message's thumbnails. Returns false when
    /// there was none (the caller pastes text instead).
    @discardableResult
    func attachImages(from pasteboard: NSPasteboard) -> Bool {
        var images: [NSImage] = []
        var otherFiles: [URL] = []
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in urls {
                if Self.isImageFile(url), let i = NSImage(contentsOf: url) { images.append(i) } else { otherFiles.append(url) }
            }
        }
        // Another kind of file (a log, a PDF): its path, which Claude can read.
        if images.isEmpty, !otherFiles.isEmpty {
            textView.insertText(otherFiles.map(\.path).joined(separator: " ") + " ", replacementRange: textView.selectedRange())
            textChanged()
            return true
        }
        if images.isEmpty, let pasted = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] {
            images = pasted
        }
        // Last resort: one image handed over as raw data of a single type — what clipboard managers do.
        if images.isEmpty, let one = NSImage(pasteboard: pasteboard) { images = [one] }
        return attach(images)
    }

    /// Is this file an image? By what it *is* (a clipboard manager's temp file often has an odd extension or
    /// none at all), falling back to reading it when the type is unknown — but never for a file of a known
    /// other kind (a PDF, a log), whose path is more useful to Claude than a picture of its first page.
    private static func isImageFile(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .image) { return true }
        // A generic or made-up type (no extension, or one macOS doesn't know) says nothing — read the file.
        if let type, !type.isDynamic, type != .data, type != .content, type != .item { return false }
        return NSImage(contentsOf: url) != nil
    }

    /// Add images to this message (the paste/drop path, and the harness).
    @discardableResult
    func attach(_ images: [NSImage]) -> Bool {
        guard !images.isEmpty else { return false }
        let added = images.compactMap { ChatImage.encoded($0) }
            .map { ChatAttachment(number: 0, data: $0.data, mediaType: $0.mediaType) }
        attachments += added
        return true
    }

    /// Numbers follow position (the badges read 1, 2, 3 whatever was removed), and the strip opens or closes.
    private func attachmentsChanged() {
        if attachments.enumerated().contains(where: { $0.element.number != $0.offset + 1 }) {
            attachments = attachments.enumerated().map { ChatAttachment(number: $0.offset + 1, data: $0.element.data,
                                                                        mediaType: $0.element.mediaType) }
            return                                  // the didSet this assignment fires does the rest
        }
        // One tile per attachment, always — a tile index is an attachment index (× and backspace rely on it).
        strip.set(attachments.map { $0.thumbnail ?? NSImage(size: NSSize(width: 1, height: 1)) })
        fitStrip()
        updateButton()
    }

    /// The strip's height for its current width (it wraps) — on every change and every resize.
    private func fitStrip() {
        // From the box (laid out already), not the strip — its own frame is set later in this pass, so it
        // still holds the old width after a resize.
        let h = strip.preferredHeight(width: max(0, box.bounds.width - 20))
        if stripHeight.constant != h { stripHeight.constant = h }
    }

    override func layout() {
        super.layout()
        fitStrip()
    }

    /// Backspace with the caret at the very start (nothing in front of it to delete) takes the last image —
    /// the keyboard's way to the strip's ×.
    fileprivate func removeLastAttachmentFromStart() -> Bool {
        let sel = textView.selectedRange()
        guard !attachments.isEmpty, sel.location == 0, sel.length == 0 else { return false }
        attachments.removeLast()
        return true
    }

    func removeAttachment(_ i: Int) {
        guard attachments.indices.contains(i) else { return }
        attachments.remove(at: i)
        focus()
    }

    /// Quick Look on the box's images, starting at the i-th.
    func previewAttachment(_ i: Int) {
        let files = attachments.compactMap { ChatImageCache.store($0.data, mediaType: $0.mediaType) }
        guard files.indices.contains(i) else { return }
        window?.makeFirstResponder(textView)        // Quick Look finds its controller up this responder chain
        onPreviewImages?(files, i)
    }

    func textDidChange(_ notification: Notification) { textChanged() }

    func textView(_ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        if !applyingVoice { userEdited(range, (text ?? "") as NSString) }
        return true
    }

    private func textChanged() {
        queueSelection = nil
        placeholder.isHidden = !textView.string.isEmpty
        tintForMode()
        resize()
        updateButton()
        updateCompletion()
    }

    /// `!` at the start is shell mode — the box turns the terminal UI's shell pink.
    private func tintForMode() {
        box.layer?.borderColor = (textView.string.hasPrefix("!") ? ChatStyle.shell.withAlphaComponent(0.75)
                                                                  : NSColor(white: 0.28, alpha: 1)).cgColor
    }

    private func resize() {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        lm.ensureLayout(for: tc)
        let line = ceil(fontSize * 1.25)
        let used = lm.usedRect(for: tc).height + 4
        heightConstraint.constant = min(max(used, line + 4), line * 10 + 4)
    }

    // MARK: - Keys (from ChatInputTextView)

    /// Returns true when the command was handled.
    fileprivate func handle(_ selector: Selector) -> Bool {
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if !completion.isHidden { acceptCompletion(completion.selected); return true }
            if let s = queueSelection { queueSelection = nil; onEditQueued?(s); return true }
            if shift { textView.insertText("\n", replacementRange: textView.selectedRange()); return true }
            submit(); return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            textView.insertText("\n", replacementRange: textView.selectedRange()); return true
        case #selector(NSResponder.cancelOperation(_:)):
            if !completion.isHidden { hideCompletion(); return true }
            if queueSelection != nil { queueSelection = nil; return true }
            // Dictating: esc ends it (the words stay) — it doesn't also stop Claude.
            if voice.state == .connecting || voice.state == .recording { voice.stop(); return true }
            onEscape?(); return true
        case #selector(NSResponder.insertBacktab(_:)):
            onCycleMode?(); return true
        case #selector(NSResponder.insertTab(_:)):
            if !completion.isHidden { acceptCompletion(completion.selected) }
            return true
        case #selector(NSResponder.moveUp(_:)):
            if !completion.isHidden { completion.move(-1); return true }
            return selectQueued(-1) || recallHistory(-1)
        case #selector(NSResponder.moveDown(_:)):
            if !completion.isHidden { completion.move(1); return true }
            return selectQueued(1) || recallHistory(1)
        default:
            return false
        }
    }

    fileprivate func cycleModeKey() { onCycleMode?() }

    /// ↑ from the first line (not while browsing history) highlights the newest queued message; ↑/↓ then move
    /// through them, and ↓ past the newest lets go.
    private func selectQueued(_ dir: Int) -> Bool {
        let n = queuedCount()
        guard n > 0 else { queueSelection = nil; return false }
        if let s = queueSelection {
            queueSelection = dir < 0 ? max(0, min(s, n - 1) - 1) : (s + 1 < n ? s + 1 : nil)
            return true
        }
        guard dir < 0, historyIndex == nil else { return false }
        let caret = textView.selectedRange().location
        if (textView.string as NSString).substring(to: caret).contains("\n") { return false }
        lastQueuedCount = n                 // the chrome may not have caught up with the queue yet
        queueSelection = n - 1
        return true
    }

    /// ↑/↓ walk sent messages — only when the caret is on the first/last line, so multi-line editing works.
    private func recallHistory(_ dir: Int) -> Bool {
        guard !history.isEmpty else { return false }
        let s = textView.string as NSString
        let caret = textView.selectedRange().location
        if dir < 0, s.substring(to: caret).contains("\n") { return false }
        if dir > 0, s.substring(from: caret).contains("\n") { return false }
        if dir < 0 {
            guard textView.string.isEmpty || historyIndex != nil else { return false }
            dropVoiceSpan()
            let i = max(0, (historyIndex ?? history.count) - 1)
            historyIndex = i
            textView.string = history[i]
        } else {
            guard let i = historyIndex else { return false }
            dropVoiceSpan()
            if i + 1 < history.count { historyIndex = i + 1; textView.string = history[i + 1] }
            else { historyIndex = nil; textView.string = "" }
        }
        placeholder.isHidden = !textView.string.isEmpty
        tintForMode()
        resize(); updateButton()
        return true
    }

    // MARK: - Voice

    func toggleVoice() {
        if voice.state == .idle { focus() }
        voice.toggle()
    }

    @objc private func micTapped() { toggleVoice() }

    private func voiceState(_ state: ChatVoice.State) {
        switch state {
        case .connecting:
            // The words go where the caret is, replacing a selection — like typing them.
            let sel = textView.selectedRange()
            let s = textView.string as NSString
            let before = sel.location > 0 ? s.character(at: sel.location - 1) : 32
            voiceLead = (before == 32 || before == 10 || before == 9) ? "" : " "
            voiceSpan = NSRange(location: sel.location, length: sel.length)
            voiceOriginal = s.substring(with: sel)
            sendAfterVoice = false
        case .idle:
            commitVoice()
            if sendAfterVoice { sendAfterVoice = false; submit() }
        case .recording, .finishing: break
        }
        placeholder.stringValue = state == .idle ? Self.placeholderText : "Listening…   fn⌃ or the mic to stop"
        updateMic()
    }

    private func voiceText(_ t: String) {
        guard let span = voiceSpan, NSMaxRange(span) <= (textView.string as NSString).length else { return }
        let new = t.isEmpty ? "" : voiceLead + t
        let sel = textView.selectedRange()
        applyingVoice = true
        // With the box's typing attributes — a bare string gets the text system's default black 12 pt.
        textView.textStorage?.replaceCharacters(in: span, with: NSAttributedString(string: new, attributes: textView.typingAttributes))
        applyingVoice = false
        let placed = NSRange(location: span.location, length: (new as NSString).length)
        voiceSpan = placed
        // The caret follows the words while it sits at their end; one you moved on (typed after them) keeps its place.
        let caret = sel.location <= NSMaxRange(span) ? NSMaxRange(placed) : sel.location + placed.length - span.length
        textView.setSelectedRange(NSRange(location: caret, length: sel.location <= NSMaxRange(span) ? 0 : sel.length))
        textView.scrollRangeToVisible(textView.selectedRange())
        textChanged()
    }

    /// Dictation over: swap the words back for what they replaced, then insert them the ordinary way, so they
    /// are one undo step and the steps before them still line up.
    private func commitVoice() {
        guard let span = voiceSpan else { return }
        voiceSpan = nil
        let s = textView.string as NSString
        guard NSMaxRange(span) <= s.length else { return }
        let spoken = s.substring(with: span)
        guard spoken != voiceOriginal else { return }
        let sel = textView.selectedRange()
        applyingVoice = true
        textView.textStorage?.replaceCharacters(in: span, with: NSAttributedString(string: voiceOriginal, attributes: textView.typingAttributes))
        // A programmatic edit, not typing (`insertText` would be merged into the typing before it).
        textView.breakUndoCoalescing()
        let range = NSRange(location: span.location, length: (voiceOriginal as NSString).length)
        if textView.shouldChangeText(in: range, replacementString: spoken) {
            textView.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: spoken, attributes: textView.typingAttributes))
            textView.didChangeText()
        }
        applyingVoice = false
        textView.setSelectedRange(sel)
    }

    /// Typing while listening means you're done talking: stop (the last words still land in their place). An
    /// edit in front of the spoken text moves it; one that runs into it lets go of it.
    private func userEdited(_ range: NSRange, _ text: NSString) {
        guard let span = voiceSpan else { return }
        if voice.state == .connecting || voice.state == .recording { voice.stop() }
        if NSMaxRange(range) <= span.location {
            voiceSpan = NSRange(location: span.location + text.length - range.length, length: span.length)
        } else if range.location < NSMaxRange(span) {
            voiceSpan = nil
        }
    }

    private func dropVoiceSpan() {
        voiceSpan = nil
        sendAfterVoice = false
        if voice.state == .connecting || voice.state == .recording { voice.stop() }
    }

    var debugVoice: [String: Any] {
        ["state": voice.state.rawValue, "text": voice.text, "error": voice.lastError ?? "",
         "span": voiceSpan.map { "\($0.location),\($0.length)" } ?? "", "mic": micButton.toolTip ?? "", "timeline": voice.timeline,
         "canUndo": window?.undoManager?.canUndo ?? false, "undoName": window?.undoManager?.undoActionName ?? "-",
         "groupLevel": window?.undoManager?.groupingLevel ?? -1]
    }

    private func updateMic() {
        let st = voice.state
        let on = st != .idle
        micButton.image = NSImage(systemSymbolName: on ? "mic.fill" : "mic", accessibilityDescription: on ? "Stop dictation" : "Dictate")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        micButton.contentTintColor = switch st {
        case .idle: NSColor(white: 0.5, alpha: 1)
        case .connecting: ChatStyle.amber
        case .recording: ChatStyle.red
        case .finishing: ChatStyle.red.withAlphaComponent(0.55)
        }
        micButton.toolTip = on ? "Stop dictation (fn⌃)" : "Dictate (fn⌃)"
        let layer = micButton.layer
        if st == .recording, layer?.animation(forKey: "pulse") == nil {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1; a.toValue = 0.35; a.duration = 0.7
            a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(a, forKey: "pulse")
        } else if st != .recording {
            layer?.removeAnimation(forKey: "pulse")
        }
    }

    // MARK: - Completion

    private enum Mode { case command, file }
    private var mode: Mode = .command
    private var tokenRange = NSRange(location: 0, length: 0)
    private var candidates: [(title: String, detail: String, insert: String)] = []

    /// Re-evaluate the popup for the current token (a completion source finished loading).
    func refreshCompletion() { if window?.firstResponder === textView { updateCompletion() } }

    private func updateCompletion() {
        let s = textView.string as NSString
        let caret = textView.selectedRange().location
        guard caret <= s.length else { hideCompletion(); return }
        // The token ending at the caret.
        var start = caret
        while start > 0 {
            let c = s.character(at: start - 1)
            if c == 32 || c == 10 || c == 9 { break }
            start -= 1
        }
        let token = s.substring(with: NSRange(location: start, length: caret - start))
        if token.hasPrefix("/") {
            // At the start of the message: every command. After a space: skills only — a built-in (/clear) means
            // nothing mid-sentence, a skill is something Claude can reach for (as the terminal UI suggests them).
            let atStart = start == 0
            let q = String(token.dropFirst()).lowercased()
            let matches = commands()
                .filter { atStart || $0.skill }
                // Mid-text, by prefix only: a path being typed ("see /api/…") mustn't turn up a skill that merely
                // contains it — ⏎ would then take the suggestion instead of sending.
                .filter { q.isEmpty || $0.name.lowercased().hasPrefix(q) || (atStart && $0.name.lowercased().contains(q)) }
                .sorted { a, b in
                    let ap = a.name.lowercased().hasPrefix(q), bp = b.name.lowercased().hasPrefix(q)
                    return ap != bp ? ap : a.name < b.name
                }
            candidates = matches.prefix(40).map { c in
                let desc = c.description.replacingOccurrences(of: "\n", with: " ")
                return ("/" + c.name + (c.hint.isEmpty ? "" : " " + c.hint), desc, "/" + c.name + " ")
            }
            mode = .command
        } else if token.hasPrefix("@") {
            let q = String(token.dropFirst()).lowercased()
            candidates = Self.rankFiles(files(), query: q).prefix(40).map { ($0, "", "@" + $0 + " ") }
            mode = .file
        } else {
            hideCompletion(); return
        }
        tokenRange = NSRange(location: start, length: caret - start)
        guard !candidates.isEmpty else { hideCompletion(); return }
        completion.set(candidates.map { ($0.title, $0.detail) })
        completion.isHidden = false
        completionHeight.constant = completion.preferredHeight
    }

    /// Basename-prefix matches first, then basename-contains, then path-contains, then subsequence.
    static func rankFiles(_ files: [String], query q: String) -> [String] {
        guard !q.isEmpty else { return Array(files.prefix(40)) }
        var scored: [(Int, Int, String)] = []
        for f in files {
            let lower = f.lowercased()
            let base = (lower as NSString).lastPathComponent
            let score: Int
            if base.hasPrefix(q) { score = 0 }
            else if base.contains(q) { score = 1 }
            else if lower.contains(q) { score = 2 }
            else if isSubsequence(q, of: lower) { score = 3 }
            else { continue }
            scored.append((score, f.count, f))
            if scored.count > 4000 { break }
        }
        return scored.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    private static func isSubsequence(_ q: String, of s: String) -> Bool {
        var it = s.makeIterator()
        outer: for c in q {
            while let x = it.next() { if x == c { continue outer } }
            return false
        }
        return true
    }

    private func acceptCompletion(_ i: Int) {
        guard candidates.indices.contains(i) else { hideCompletion(); return }
        let insert = candidates[i].insert
        textView.insertText(insert, replacementRange: tokenRange)
        hideCompletion()
        placeholder.isHidden = !textView.string.isEmpty
        tintForMode()
        resize(); updateButton()
    }

    func hideCompletion() {
        guard !completion.isHidden else { return }
        completion.isHidden = true
        completionHeight.constant = 0
    }

    var completionVisible: Bool { !completion.isHidden }
    var completionTitles: [String] { completion.isHidden ? [] : candidates.map(\.title) }
}

/// The input's text view: routes the special keys to `ChatInputView` before AppKit's defaults.
final class ChatInputTextView: NSTextView {
    fileprivate weak var owner: ChatInputView?

    /// None while dictation streams words in (see `ChatInputView.dictating`).
    override var undoManager: UndoManager? { owner?.dictating == true ? nil : super.undoManager }

    override func doCommand(by selector: Selector) {
        if owner?.handle(selector) == true { return }
        super.doCommand(by: selector)
    }

    /// ⇧⇥ cycles the permission mode. Caught here from the event itself: AppKit's key bindings turn Shift-Tab
    /// into `insertTab:` in a text view (not `insertBacktab:`), and the command alone doesn't say Shift was held.
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 48, mods == .shift { owner?.cycleModeKey(); return }
        super.keyDown(with: event)
    }

    /// Image types a plain-text view would otherwise ignore. AppKit decides whether Edit ▸ Paste (and so ⌘V)
    /// is even enabled by matching the clipboard against this list, and a plain-text view lists only text
    /// shapes — so an image-only clipboard left ⌘V dead and `paste(_:)` below was never called. Claiming the
    /// image types here re-enables the key; we intercept in `paste(_:)` before any of them reaches the text.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + Self.imageTypes
    }

    // No PDF here on purpose: a PDF's path is more useful to Claude than a picture of its first page
    // (`isImageFile` makes the same call), and claiming the type would paste that picture instead.
    private static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, .fileURL,
        .init("public.jpeg"), .init("public.heic"), .init("public.heif"),
        .init("com.compuserve.gif"), .init("com.microsoft.bmp"), .init("public.image"),
    ]

    override func deleteBackward(_ sender: Any?) {
        if owner?.removeLastAttachmentFromStart() == true { return }
        super.deleteBackward(sender)
    }

    // Plain-text paste (no rich formatting from the clipboard).
    override func paste(_ sender: Any?) {
        if takeImages(from: .general) { return }
        pasteAsPlainText(sender)
    }

    /// ⌘⇧V, and the route some clipboard managers use.
    override func pasteAsPlainText(_ sender: Any?) {
        if takeImages(from: .general) { return }
        super.pasteAsPlainText(sender)
    }

    /// The funnel every paste-like insertion goes through (paste, services, a drop) — the catch-all for
    /// clipboard managers that don't go through `paste:`.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if takeImages(from: pboard) { return true }
        return super.readSelection(from: pboard, type: type)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if takeImages(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    private func takeImages(from pasteboard: NSPasteboard) -> Bool {
        owner?.attachImages(from: pasteboard) == true
    }
}

/// The completion list above the input: up to 8 rows (name + dim description), keyboard- and mouse-driven.
final class ChatCompletionView: NSView {
    override var isFlipped: Bool { true }
    private var rows: [(String, String)] = []
    private(set) var selected = 0
    private var top = 0
    private let visible = 8
    var fontSize: CGFloat = 13
    var onPick: ((Int) -> Void)?
    private var rowH: CGFloat { ceil(fontSize * 1.9) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.98).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0.28, alpha: 1).cgColor
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var preferredHeight: CGFloat { CGFloat(min(rows.count, visible)) * rowH + 8 }

    /// Replace the rows; the selection starts on the first — or on the last (scrolled into view) for a
    /// list that reads oldest → newest.
    func set(_ r: [(String, String)], selectLast: Bool = false) {
        rows = r
        selected = selectLast ? max(0, r.count - 1) : 0
        top = selectLast ? max(0, r.count - visible) : 0
        needsDisplay = true
    }

    func move(_ d: Int) {
        guard !rows.isEmpty else { return }
        selected = (selected + d + rows.count) % rows.count
        if selected < top { top = selected }
        if selected >= top + visible { top = selected - visible + 1 }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                                                        .foregroundColor: NSColor(white: 0.92, alpha: 1)]
        let descAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize - 1),
                                                        .foregroundColor: NSColor(white: 0.52, alpha: 1)]
        for (n, i) in (top..<min(rows.count, top + visible)).enumerated() {
            let r = NSRect(x: 4, y: 4 + CGFloat(n) * rowH, width: bounds.width - 8, height: rowH)
            if i == selected {
                NSColor(white: 1, alpha: 0.09).setFill()
                NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            }
            let name = NSAttributedString(string: rows[i].0, attributes: nameAttrs)
            let nameW = min(name.size().width, r.width * 0.45)
            let ty = r.minY + (rowH - name.size().height) / 2
            name.draw(with: NSRect(x: r.minX + 8, y: ty, width: nameW, height: rowH), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if !rows[i].1.isEmpty {
                let desc = NSAttributedString(string: rows[i].1, attributes: descAttrs)
                let x = r.minX + 8 + nameW + 14
                desc.draw(with: NSRect(x: x, y: ty + 1, width: max(0, r.maxX - x - 8), height: rowH - 4),
                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = top + Int((p.y - 4) / rowH)
        if rows.indices.contains(i) { onPick?(i) }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
