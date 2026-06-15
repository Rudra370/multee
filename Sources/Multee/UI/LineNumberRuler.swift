import AppKit

/// A VS Code-style line-number gutter for the editor, drawn as the scroll view's vertical `NSRulerView`.
///
/// Performance: only the lines intersecting the visible rect are drawn on each pass (not the whole
/// file), and the mapping "character index → line number" is a binary search over a cached array of
/// line-start offsets (`lineStarts`) that is rebuilt only when the text changes — so scrolling a
/// 100k-line file stays cheap. Wrapped logical lines show their number once (on the first visual row),
/// matching VS Code; a trailing empty line (file ends in a newline) gets its own number too.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]      // char offset of each logical line start; always begins with 0
    private var lineStartsDirty = true

    private static let numberColor  = NSColor(white: 0.42, alpha: 1)   // dim, like VS Code's gutter
    private static let currentColor = NSColor(white: 0.78, alpha: 1)   // the cursor's line, brighter
    private let rightPadding: CGFloat = 8
    private let leftPadding: CGFloat = 6

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40

        // Redraw on scroll (the document clip view moves) and on text/selection changes.
        scrollView.contentView.postsBoundsChangedNotifications = true
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(viewDidScroll),
                       name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        nc.addObserver(self, selector: #selector(textDidChange),
                       name: NSText.didChangeNotification, object: textView)
        nc.addObserver(self, selector: #selector(selectionDidChange),
                       name: NSTextView.didChangeSelectionNotification, object: textView)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Editor font changed (Cmd +/−): the gutter font and width track it.
    var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet { recomputeThickness(); needsDisplay = true }
    }

    @objc private func viewDidScroll()       { needsDisplay = true }
    @objc private func selectionDidChange()  { needsDisplay = true }
    @objc private func textDidChange() {
        lineStartsDirty = true
        recomputeThickness()
        needsDisplay = true
    }

    /// Called when the document is replaced wholesale (initial load, retarget) without a text edit.
    func reload() {
        lineStartsDirty = true
        recomputeThickness()
        needsDisplay = true
    }

    // MARK: Line-start index (cached; rebuilt only on text change)

    private func rebuildLineStartsIfNeeded() {
        guard lineStartsDirty, let ns = textView?.string as NSString? else { return }
        lineStartsDirty = false
        var starts: [Int] = [0]
        var idx = 0
        while idx < ns.length {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: idx, length: ns.length - idx))
            if r.location == NSNotFound { break }
            starts.append(r.location + 1)            // start of the line after this newline
            idx = r.location + 1
        }
        lineStarts = starts                          // a trailing "\n" leaves a final start == length (empty last line)
    }

    /// 1-based (line, column) for a character index — for the status bar. Reuses the cached line index.
    func lineColumn(at charIndex: Int) -> (line: Int, column: Int) {
        rebuildLineStartsIfNeeded()
        let line = lineNumber(for: charIndex)
        return (line, charIndex - lineStarts[line - 1] + 1)
    }

    /// 1-based line number containing `charIndex` (binary search for the greatest start ≤ charIndex).
    private func lineNumber(for charIndex: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1, ans = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lineStarts[mid] <= charIndex { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans + 1
    }

    private func recomputeThickness() {
        rebuildLineStartsIfNeeded()
        let digits = max(2, String(lineStarts.count).count)
        let sample = String(repeating: "8", count: digits)
        let w = sample.size(withAttributes: [.font: font]).width
        ruleThickness = ceil(w) + leftPadding + rightPadding
    }

    // MARK: Drawing

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let lm = textView.layoutManager else { return }
        rebuildLineStartsIfNeeded()

        TMTheme.background.setFill()
        bounds.fill()

        let ns = textView.string as NSString
        let inset = textView.textContainerInset.height
        // Everything below is in *viewport* coordinates: y == 0 is the top of the visible area, growing
        // downward (the ruler is flipped). `textView.visibleRect.minY` is the current scroll offset
        // (the clip view's bounds origin is NOT reliable here), so a line fragment at container-y `F`
        // sits at viewport-y `inset + F - scrollOffset`.
        let visible = textView.visibleRect
        let curLine = lineNumber(for: textView.selectedRange().location)

        // Start at the first logical line whose fragment reaches the viewport top — a binary search over
        // fragment tops (O(log n)), so a deep scroll doesn't scan every line above the fold each redraw.
        var line = firstVisibleLine(at: visible.minY, inset: inset, lm: lm, ns: ns)

        while line < lineStarts.count {
            let fragRect = fragmentRect(forLine: line, lm: lm, ns: ns)
            let y = inset + fragRect.minY - visible.minY
            if y > visible.height { break }            // below the viewport bottom — done
            if y + fragRect.height >= 0 {              // intersects the viewport — draw it
                let n = line + 1
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: n == curLine ? Self.currentColor : Self.numberColor,
                ]
                let s = String(n) as NSString
                let size = s.size(withAttributes: attrs)
                let drawX = ruleThickness - size.width - rightPadding
                let drawY = y + (fragRect.height - size.height) / 2
                s.draw(at: NSPoint(x: drawX, y: drawY), withAttributes: attrs)
            }
            line += 1
        }
    }

    /// Layout rect of a logical line's first visual row (or the extra fragment for an empty trailing line).
    private func fragmentRect(forLine i: Int, lm: NSLayoutManager, ns: NSString) -> NSRect {
        let startChar = lineStarts[i]
        guard startChar < ns.length else { return lm.extraLineFragmentRect }
        return lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: startChar), effectiveRange: nil)
    }

    /// Greatest line index whose fragment top is at/above `viewTop` — i.e. the first line to draw.
    /// Binary search so a deep scroll costs O(log n) layout probes, not one per line above the fold.
    private func firstVisibleLine(at viewTop: CGFloat, inset: CGFloat, lm: NSLayoutManager, ns: NSString) -> Int {
        var lo = 0, hi = lineStarts.count - 1, ans = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if fragmentRect(forLine: mid, lm: lm, ns: ns).minY + inset <= viewTop { ans = mid; lo = mid + 1 }
            else { hi = mid - 1 }
        }
        return ans
    }
}
