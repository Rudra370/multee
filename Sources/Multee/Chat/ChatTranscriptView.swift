import AppKit
import QuartzCore
import Quartz

/// Where a row's text sits for a given list width. Shared by measuring and layout so a precomputed height
/// is exactly the height the row draws at.
enum ChatRowGeometry {
    static let maxColumn: CGFloat = 920
    static let gutter: CGFloat = 22

    static func column(_ width: CGFloat) -> (x: CGFloat, w: CGFloat) {
        let w = max(120, min(width - 40, maxColumn))
        return (max(12, floor((width - w) / 2)), w)
    }

    /// Text inset within the row: (left from column start, right, top, bottom).
    static func insets(_ kind: ChatItem.Kind) -> (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
        switch kind {
        case .user:               return (14, 14, 12 + 9, 9 + 8)     // 12pt gap above the bubble, 9pt padding
        case .assistant:          return (gutter, 6, 7, 7)
        case .tool:               return (gutter, 6, 5, 5)
        case .thinking:           return (gutter, 6, 4, 4)
        case .notice, .error:     return (gutter, 6, 4, 4)
        }
    }

    static func textWidth(_ kind: ChatItem.Kind, rowWidth: CGFloat) -> CGFloat {
        let c = column(rowWidth), i = insets(kind)
        return max(40, c.w - i.left - i.right)
    }
}

/// The scrolling chat transcript: a hand-rolled virtual list (prefix-sum row offsets, binary-searched
/// visible range, a small pool of reused row views). Every row height is **measured exactly before it is
/// shown** — with the same TextKit 1 stack the row renders with — so nothing is ever estimated and later
/// corrected. That correction is what makes long chats jump/stutter when scrolling up; here the content
/// height is always true. Streaming updates re-render only the changed row, throttled to ~30 fps, and the
/// viewport is anchored (pinned to the bottom while following, else to the first visible row).
final class ChatTranscriptView: NSView {
    private struct RowCache { var version: Int; var fontSize: CGFloat; var attr: NSAttributedString; var width: CGFloat; var height: CGFloat }

    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private let header = ChatHistoryHeader()
    private let jumpButton = PointerButton()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let rail = ChatJumpRail()
    private let jumpList = ChatJumpList()
    private var userRows: [Int] = []               // row index of each message you sent, in order (the rail's lines)
    private var overRail = false, overList = false
    private var jumpedTo: Int?                     // the message a jump landed on — current until you scroll
    private var jumpGliding = false                // a jump's animated scroll is running (its bounds changes aren't "you scrolled")
    private var jumpToken = 0                      // the latest jump — an earlier glide cut short doesn't finish it
    private var collapsed = Set<Int>()             // item ids of your messages whose reply is folded away
    private var folds: [Fold] = []                 // parallel to rowIDs
    private enum Fold { case shown, hidden, head } // head = a collapsed message (row grows by the stub)
    private var hoverWork: DispatchWorkItem?

    private weak var session: ChatSession?
    private(set) var style: ChatStyle
    private let cwd: String

    private var rowIDs: [Int] = []                 // item id of each laid-out row (== session.items when in sync)
    private var heights: [CGFloat] = []            // parallel to rowIDs
    private var offsets: [CGFloat] = [0]           // offsets[i] = top of row i (after the header)
    private var cache: [Int: RowCache] = [:]       // item id → rendered + measured
    private var live: [Int: ChatRowView] = [:]     // item id → mounted row
    private var pool: [ChatRowView] = []
    private let measurer = ChatMeasurer()
    private var measuredWidth: CGFloat = 0
    private var headerHeight: CGFloat = 10
    private let bottomPad: CGFloat = 16

    private(set) var following = true
    private var lastViewportHeight: CGFloat = 0
    private var adjusting = false                   // our own scroll moves — don't recompute `following`
    private var dirty = Set<Int>()                  // item ids changed since the last flush
    private var flushScheduled = false
    private var lastFlush: CFTimeInterval = 0
    private var pendingRelayout = false
    private var preparing = false                   // an off-main render/measure pass is running
    private var syncAfterPrepare = false            // …and the rows need reconciling again when it lands
    private var pendingAnchor: Anchor?              // the viewport to restore once that pass lands

    var onToggle: ((Int) -> Void)?                  // "show more" link → item id
    var onLoadEarlier: (() -> Void)?
    var onTypeAhead: ((NSEvent) -> Void)?           // a key typed while a message is focused → the input
    var onPicture: ((Int, Int) -> Void)?            // a sent image clicked → item id, image index

    /// The harness's stand-in for clicking a picture: the same path as `ChatRowTextView.mouseDown` — that row's
    /// text becomes first responder, then the picture opens. False when the row isn't on screen.
    func debugClickPicture(itemID: Int, index: Int) -> Bool {
        guard let row = live[itemID] else { return false }
        return row.debugClickPicture(index)
    }

    // DEV instrumentation
    private(set) var tileCount = 0
    private(set) var maxTileMs: Double = 0

    init(session: ChatSession, style: ChatStyle, cwd: String) {
        self.session = session
        self.style = style
        self.cwd = cwd
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        wantsLayer = true

        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .allowed
        scroll.translatesAutoresizingMaskIntoConstraints = false
        doc.wantsLayer = true
        doc.frame = NSRect(x: 0, y: 0, width: 800, height: 10)
        doc.autoresizingMask = [.width]
        scroll.documentView = doc
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(scroll)

        header.onLoad = { [weak self] in self?.onLoadEarlier?() }
        doc.addSubview(header)

        jumpButton.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: "Jump to latest")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        jumpButton.isBordered = false
        jumpButton.wantsLayer = true
        jumpButton.layer?.cornerRadius = 15
        jumpButton.layer?.backgroundColor = NSColor(white: 0.24, alpha: 0.95).cgColor
        jumpButton.layer?.borderWidth = 1
        jumpButton.layer?.borderColor = NSColor(white: 0.36, alpha: 1).cgColor
        jumpButton.contentTintColor = NSColor(white: 0.9, alpha: 1)
        jumpButton.toolTip = "Jump to latest"
        jumpButton.target = self
        jumpButton.action = #selector(jumpTapped)
        jumpButton.isHidden = true
        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(jumpButton)

        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        rail.onJump = { [weak self] i in self?.jump(toMessage: i) }
        rail.onHover = { [weak self] on in self?.overRail = on; self?.hoverChanged() }
        addSubview(rail)
        jumpList.onJump = { [weak self] i in self?.jump(toMessage: i) }
        jumpList.onClose = { [weak self] in self?.hideJumpList() }
        jumpList.onHover = { [weak self] on in self?.overList = on; self?.hoverChanged() }
        jumpList.isHidden = true
        addSubview(jumpList)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            jumpButton.widthAnchor.constraint(equalToConstant: 30),
            jumpButton.heightAnchor.constraint(equalToConstant: 30),
            jumpButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            jumpButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    private var items: [ChatItem] { session?.items ?? [] }
    private var rowWidth: CGFloat { scroll.contentView.bounds.width }

    // MARK: - Session changes

    func setStyle(_ s: ChatStyle) {
        style = s
        reloadAll()
    }

    /// Re-lay every row (first show, font change). Big transcripts render + measure off-main first.
    func reloadAll() { syncRows(anchor: captureAnchor()) }

    /// Forget every rendered row (the session switched to another conversation).
    func purgeCache() {
        cache.removeAll()
        for (_, v) in live { recycle(v) }
        live.removeAll()
        rowIDs.removeAll(); heights.removeAll(); offsets = [0]
        following = true
        setUserRows([])
        collapsed.removeAll(); folds.removeAll()
    }

    func appended(_ range: Range<Int>) {
        // Fast path: the rows were in sync up to here — measure just the new items.
        guard inSync(upTo: range.lowerBound), !preparing, rowWidth > 10 else { syncRows(anchor: captureAnchor()); return }
        let width = rowWidth
        let wasFollowing = following
        let items = self.items
        for i in range {
            heights.append(row(for: items[i], width: width).height)
            rowIDs.append(items[i].id)
        }
        setUserRows(userRows + range.filter { items[$0].kind == .user })
        rebuildOffsets(from: min(range.lowerBound, rebuildFolds() ?? .max))
        updateEmptyState()
        if wasFollowing { scrollToBottom() } else { tile() }
    }

    /// History landed above: keep the viewport exactly where it was (or pinned to the bottom).
    func prepended(_ count: Int) { syncRows(anchor: captureAnchor()) }

    func changed(_ index: Int) {
        guard items.indices.contains(index) else { return }
        dirty.insert(items[index].id)
        scheduleFlush()
    }

    func stateChanged() {
        updateHeader()
        updateEmptyState()
    }

    private func inSync(upTo n: Int) -> Bool {
        guard rowIDs.count == n else { return false }
        let items = self.items
        return n == 0 || (items.count >= n && items[n - 1].id == rowIDs[n - 1] && items[0].id == rowIDs[0])
    }

    /// The one reconcile path: make rows == session.items at the current width. Items without a fresh
    /// render/measurement are prepared — synchronously when few, else in one off-main pass, after which
    /// this runs again. Passes are never dropped or overlapped, so no item can be left without a row.
    private func syncRows(anchor: Anchor?) {
        let width = rowWidth
        guard width > 10 else { return }
        if pendingAnchor == nil { pendingAnchor = anchor }
        if preparing { syncAfterPrepare = true; return }
        let items = self.items
        let stale = items.filter { !isFresh($0, width) }
        if stale.count > 60 {
            preparing = true
            prepareOffMain(stale, width: width) { [weak self] in
                guard let self else { return }
                self.preparing = false
                self.syncAfterPrepare = false
                self.syncRows(anchor: nil)
            }
            return
        }
        heights = items.map { row(for: $0, width: width).height }
        rowIDs = items.map(\.id)
        setUserRows(items.indices.filter { items[$0].kind == .user })
        _ = rebuildFolds()
        measuredWidth = width
        let a = pendingAnchor
        pendingAnchor = nil
        for (id, v) in live {
            if let i = session?.index(of: id), let c = cache[id] { v.configure(items[i], cache: c.attr, width: width) }
        }
        rebuildOffsets(from: 0)
        updateHeader()
        updateEmptyState()
        if following || a == nil { scrollToBottom() } else { restore(a) }
    }

    private func isFresh(_ item: ChatItem, _ width: CGFloat) -> Bool {
        guard let c = cache[item.id] else { return false }
        return c.version == item.version && c.fontSize == style.size && c.width == width
    }

    // MARK: - Flush (throttled row updates)

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        // ~16 updates/s while a reply streams: smooth to read, and each update re-lays the growing message.
        let wait = max(0, 0.06 - (CACurrentMediaTime() - lastFlush))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        lastFlush = CACurrentMediaTime()
        guard !dirty.isEmpty, let session else { return }
        let items = self.items
        guard !preparing, inSync(upTo: items.count) else { dirty.removeAll(); syncRows(anchor: captureAnchor()); return }
        let width = rowWidth
        let ids = dirty
        dirty.removeAll()
        let anchor = following ? nil : captureAnchor()
        var lowest = Int.max
        for id in ids {
            guard let i = session.index(of: id) else { continue }
            let h: CGFloat
            if let v = live[id] {
                // On screen (the streaming reply): lay it out once, in its own text view, and read the
                // height from that — instead of measuring in the measurer and laying out again to draw.
                let attr = ChatRender.render(items[i], style: style, cwd: cwd)
                // In-place tail updates while it streams; one full replace when it completes, so the final
                // text is exactly the fresh render even if an earlier paragraph restyled.
                v.configure(items[i], cache: attr, width: width, incremental: items[i].streaming)
                h = rowHeight(items[i].kind, v.textHeight())
                cache[id] = RowCache(version: items[i].version, fontSize: style.size, attr: attr, width: width, height: h)
            } else {
                h = row(for: items[i], width: width).height
            }
            if heights[i] != h { heights[i] = h; lowest = min(lowest, i) }
        }
        if lowest != Int.max { rebuildOffsets(from: lowest) }
        if following { scrollToBottom() } else if let anchor { restore(anchor) } else { tile() }
    }

    // MARK: - Rendering cache

    /// Render + measure one item at `width`, reusing the cache when nothing changed.
    private func row(for item: ChatItem, width: CGFloat) -> RowCache {
        if let c = cache[item.id], c.version == item.version, c.fontSize == style.size {
            if c.width == width { return c }
            var m = c
            m.width = width
            m.height = rowHeight(item.kind, measurer.height(c.attr, width: ChatRowGeometry.textWidth(item.kind, rowWidth: width)))
            cache[item.id] = m
            return m
        }
        let attr = ChatRender.render(item, style: style, cwd: cwd)
        let h = rowHeight(item.kind, measurer.height(attr, width: ChatRowGeometry.textWidth(item.kind, rowWidth: width)))
        let c = RowCache(version: item.version, fontSize: style.size, attr: attr, width: width, height: h)
        cache[item.id] = c
        return c
    }

    private func rowHeight(_ kind: ChatItem.Kind, _ text: CGFloat) -> CGFloat {
        let i = ChatRowGeometry.insets(kind)
        return text + i.top + i.bottom
    }

    /// Render + measure many items in parallel off the main thread, then hand the results to the
    /// main-thread cache (only where the item hasn't changed since the snapshot).
    private func prepareOffMain(_ snapshot: [ChatItem], width: CGFloat, then done: @escaping () -> Void) {
        let style = self.style, cwd = self.cwd
        let existing = snapshot.map { item -> NSAttributedString? in
            guard let c = cache[item.id], c.version == item.version, c.fontSize == style.size else { return nil }
            return c.attr
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var results = [RowCache?](repeating: nil, count: snapshot.count)
            let chunk = 64
            let chunks = (snapshot.count + chunk - 1) / chunk
            results.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    let m = ChatMeasurer()
                    for i in (c * chunk)..<min(snapshot.count, (c + 1) * chunk) {
                        autoreleasepool {
                            let item = snapshot[i]
                            let attr = existing[i] ?? ChatRender.render(item, style: style, cwd: cwd)
                            let text = m.height(attr, width: ChatRowGeometry.textWidth(item.kind, rowWidth: width))
                            let ins = ChatRowGeometry.insets(item.kind)
                            buf[i] = RowCache(version: item.version, fontSize: style.size, attr: attr, width: width,
                                              height: text + ins.top + ins.bottom)
                        }
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for (i, r) in results.enumerated() {
                    guard let r else { continue }
                    let id = snapshot[i].id
                    if let cur = self.session?.index(of: id), self.items[cur].version == r.version { self.cache[id] = r }
                }
                done()
            }
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let width = rowWidth
        guard width > 10 else { return }
        // The viewport got shorter or taller — a prompt card or panel opened below, the window resized. A
        // frame change posts no bounds notification, so this is where it shows: stay on the bottom if following.
        let viewport = scroll.contentView.bounds.height
        let resized = abs(viewport - lastViewportHeight) > 0.5
        lastViewportHeight = viewport
        if abs(width - measuredWidth) > 0.5 {
            if inLiveResize && !heights.isEmpty {
                pendingRelayout = true            // reflow once when the drag ends (keeps the drag smooth)
                tile()
            } else {
                syncRows(anchor: captureAnchor())
            }
        } else if resized, following {
            rebuildOffsets(from: heights.count)   // the document is at least as tall as the viewport
            scrollToBottom()
        } else {
            tile()
        }
        layoutJump()
        layoutRail()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if pendingRelayout { pendingRelayout = false; syncRows(anchor: captureAnchor()) }
    }

    private func rebuildOffsets(from start: Int) {
        let n = heights.count
        if offsets.count != n + 1 { offsets = [CGFloat](repeating: 0, count: n + 1); return rebuildOffsets(from: 0) }
        var acc = start == 0 ? 0 : offsets[start]
        for i in start..<n { offsets[i] = acc; acc += shownHeight(i) }
        offsets[n] = acc
        let total = headerHeight + acc + bottomPad
        let h = max(total, scroll.contentView.bounds.height)
        if abs(doc.frame.height - h) > 0.25 || abs(doc.frame.width - rowWidth) > 0.25 {
            adjusting = true
            doc.setFrameSize(NSSize(width: rowWidth, height: h))
            adjusting = false
        }
    }

    /// First row whose bottom is below `y` (doc coordinates, header excluded).
    private func rowIndex(atY y: CGFloat) -> Int {
        let n = heights.count
        guard n > 0 else { return 0 }
        var lo = 0, hi = n - 1
        let target = y - headerHeight
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if offsets[mid] <= target { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Mount rows intersecting the viewport (+ overscan), recycle the rest. Works from `rowIDs`, so it stays
    /// correct even while the session has items the rows haven't caught up with yet.
    private func tile() {
        let t0 = CACurrentMediaTime()
        header.frame = NSRect(x: 0, y: 0, width: rowWidth, height: headerHeight)
        guard !heights.isEmpty, let session else {
            for (_, v) in live { recycle(v) }
            live.removeAll()
            return
        }
        let vis = scroll.contentView.bounds.insetBy(dx: 0, dy: -400)
        let a = rowIndex(atY: max(0, vis.minY))
        let b = rowIndex(atY: vis.maxY)
        let width = rowWidth
        let keep = Set((a...b).lazy.filter { !self.isHidden($0) }.map { self.rowIDs[$0] })
        for (id, v) in live where !keep.contains(id) {
            recycle(v)
            live[id] = nil
        }
        let items = session.items
        for i in a...b where !isHidden(i) {
            let id = rowIDs[i]
            let f = NSRect(x: 0, y: headerHeight + offsets[i], width: width, height: shownHeight(i))
            if let v = live[id] {
                if v.frame != f { v.frame = f }
                v.setFold(foldState(i))
                continue
            }
            guard let idx = session.index(of: id) else { continue }
            let v = pool.popLast() ?? makeRow()
            v.frame = f
            let c = cache[id] ?? row(for: items[idx], width: width)
            v.configure(items[idx], cache: c.attr, width: width)
            v.setFold(foldState(i))
            v.isHidden = false
            live[id] = v
        }
        rail.set(count: userRows.count, current: currentMessage())
        tileCount += 1
        maxTileMs = max(maxTileMs, (CACurrentMediaTime() - t0) * 1000)
    }

    /// Park a row in the pool. `prepareForReuse` first: NSView's default un-hides the view, so hiding before
    /// it left every recycled row drawn where it last was (ghost rows after a rewind or a /resume switch).
    private func recycle(_ v: ChatRowView) {
        v.prepareForReuse()
        v.isHidden = true
        pool.append(v)
    }

    private func makeRow() -> ChatRowView {
        let v = ChatRowView()
        v.cursorsOff = jumpList.isOpen
        v.onFold = { [weak self] id, all in self?.toggleFold(id, all: all) }
        v.onToggle = { [weak self] id in self?.onToggle?(id) }
        v.onTypeAhead = { [weak self] e in self?.onTypeAhead?(e) }
        v.onPicture = { [weak self] id, i in self?.onPicture?(id, i) }
        doc.addSubview(v)
        return v
    }

    // MARK: - Scrolling & anchoring

    private struct Anchor { let id: Int; let delta: CGFloat }

    /// Row index of an item id — ids ascend with position, so a binary search.
    private func rowPosition(of id: Int) -> Int? {
        var lo = 0, hi = rowIDs.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if rowIDs[mid] == id { return mid }
            if rowIDs[mid] < id { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    private func captureAnchor() -> Anchor? {
        guard !heights.isEmpty else { return nil }
        let y = scroll.contentView.bounds.minY
        let i = rowIndex(atY: y)
        return Anchor(id: rowIDs[i], delta: y - (headerHeight + offsets[i]))
    }

    private func restore(_ a: Anchor?) {
        guard let a, let i = rowPosition(of: a.id) else { tile(); return }
        setScrollY(headerHeight + offsets[i] + a.delta)
    }

    private func setScrollY(_ y: CGFloat) {
        let clip = scroll.contentView
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        adjusting = true
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        scroll.reflectScrolledClipView(clip)
        adjusting = false
        tile()
    }

    func scrollToBottom() {
        following = true
        setScrollY(.greatestFiniteMagnitude)
        jumpButton.isHidden = true
    }

    @objc private func jumpTapped() { scrollToBottom() }

    @objc private func boundsChanged() {
        let clip = scroll.contentView.bounds
        // Resized rather than scrolled (if this runs before `layout` sees the new height): a transcript
        // following the bottom stays on it instead of losing its last lines.
        let resized = abs(clip.height - lastViewportHeight) > 0.5
        lastViewportHeight = clip.height
        if resized, following, !adjusting { setScrollY(.greatestFiniteMagnitude); return }
        if !adjusting, !jumpGliding { jumpedTo = nil }   // you scrolled: the highlight follows the view again
        tile()
        guard !adjusting else { return }
        let atBottom = clip.maxY >= doc.frame.height - 40
        if atBottom != following { following = atBottom }
        jumpButton.isHidden = following
        // Reaching the top pulls in earlier history (the header's button does the same) — not mid-glide: the
        // taller header and the rows landing above would move the content under a jump still heading for the
        // old spot. The jump checks once it lands.
        if clip.minY < 300, !jumpGliding, session?.canLoadEarlier == true { onLoadEarlier?() }
    }

    private func layoutJump() { jumpButton.isHidden = following }

    private func updateHeader() {
        guard let session else { return }
        let old = headerHeight
        if session.historyLoading { header.set(.loading) ; headerHeight = 40 }
        else if session.canLoadEarlier { header.set(.more); headerHeight = 40 }
        else { header.set(.none); headerHeight = 10 }
        if old != headerHeight {
            let anchor = following ? nil : captureAnchor()
            rebuildOffsets(from: 0)
            if following { scrollToBottom() } else { restore(anchor) }
        }
    }

    private func updateEmptyState() {
        let empty = items.isEmpty && session?.historyLoading != true
        emptyLabel.isHidden = !empty
        guard empty else { return }
        let folder = (cwd as NSString).lastPathComponent
        let s = NSMutableAttributedString(string: "Ask Claude about \(folder)\n", attributes: [
            .font: NSFont.systemFont(ofSize: style.size + 3, weight: .semibold), .foregroundColor: NSColor(white: 0.8, alpha: 1)])
        let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineSpacing = 3; p.paragraphSpacingBefore = 6
        s.append(NSAttributedString(string: "/ for commands  ·  @ to mention a file  ·  ⇧⇥ to switch mode  ·  esc to stop", attributes: [
            .font: NSFont.systemFont(ofSize: style.size - 1), .foregroundColor: ChatStyle.faint, .paragraphStyle: p]))
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        emptyLabel.attributedStringValue = s
    }

    // MARK: - Folding replies

    /// Rows inside a collapsed reply get no height and are never mounted; the message itself grows by the
    /// stub ("Show Claude's reply"). Rows stay in `rowIDs`, so ids, history and rewind are untouched.
    private func shownHeight(_ i: Int) -> CGFloat {
        guard i < folds.count else { return heights[i] }
        switch folds[i] {
        case .shown: return heights[i]
        case .hidden: return 0
        case .head: return heights[i] + ChatRowView.stubHeight
        }
    }
    private func isHidden(_ i: Int) -> Bool { i < folds.count && folds[i] == .hidden }

    /// (has a reply to fold, is folded) for a row — only your messages have either.
    private func foldState(_ i: Int) -> (collapsible: Bool, collapsed: Bool) {
        var lo = 0, hi = userRows.count - 1, found: Int?        // runs per mounted row while scrolling: binary search
        while lo <= hi {
            let mid = (lo + hi) / 2
            if userRows[mid] == i { found = mid; break }
            if userRows[mid] < i { lo = mid + 1 } else { hi = mid - 1 }
        }
        guard let k = found else { return (false, false) }
        let end = k + 1 < userRows.count ? userRows[k + 1] : rowIDs.count
        return (end > i + 1, i < folds.count && folds[i] == .head)
    }

    /// Recompute `folds` from `collapsed`; returns the first row whose fold changed (offsets redo from there).
    @discardableResult
    private func rebuildFolds() -> Int? {
        var new = [Fold](repeating: .shown, count: rowIDs.count)
        if !collapsed.isEmpty {
            for (k, r) in userRows.enumerated() where r < new.count && collapsed.contains(rowIDs[r]) {
                let end = min(k + 1 < userRows.count ? userRows[k + 1] : new.count, new.count)
                guard end > r + 1 else { continue }          // nothing to fold yet
                new[r] = .head
                for j in (r + 1)..<end { new[j] = .hidden }
            }
        }
        defer { folds = new }
        if new.count != folds.count { return 0 }
        return new.indices.first { new[$0] != folds[$0] }
    }

    /// Fold / unfold the reply under message `id` — or, with ⌥, every reply the same way — keeping that
    /// message where it is on screen.
    func toggleFold(_ id: Int, all: Bool) {
        guard let r = rowPosition(of: id) else { return }
        let fold = !collapsed.contains(id)
        let oldOffsets = offsets, oldFolds = folds, oldMinY = scroll.contentView.bounds.minY
        let screenY = headerHeight + offsets[r] - oldMinY
        if all {
            collapsed = fold ? Set(userRows.filter { foldState($0).collapsible }.map { rowIDs[$0] }) : []
        } else if fold { collapsed.insert(id) } else { collapsed.remove(id) }
        guard let low = rebuildFolds() else { return }
        rebuildOffsets(from: low)
        for (lid, v) in live { if let i = rowPosition(of: lid) { v.setFold(foldState(i)) } }
        following = false
        setScrollY(headerHeight + offsets[r] - screenY)
        following = scroll.contentView.bounds.maxY >= doc.frame.height - 40
        jumpButton.isHidden = following
        animateFold(oldOffsets: oldOffsets, oldFolds: oldFolds, oldMinY: oldMinY)
    }

    /// The layout already changed; make it look like it moved: rows that stayed visible slide from where they
    /// were on screen (a layer transform — no relayout per frame), rows a fold just revealed fade in.
    private func animateFold(oldOffsets: [CGFloat], oldFolds: [Fold], oldMinY: CGFloat) {
        guard !Motion.reduceMotion else { return }
        // Row layers use the view's own top-down y (measured — `isGeometryFlipped` reads false, and trusting it
        // slid every row in from the wrong side).
        let minY = scroll.contentView.bounds.minY
        let now = CACurrentMediaTime()
        for (id, v) in live {
            guard let i = rowPosition(of: id), let layer = v.layer else { continue }
            let a: CABasicAnimation
            if i < oldFolds.count, oldFolds[i] == .hidden {
                // Fade in once the rows below have slid out of the way (recorded: any earlier and the ease-out
                // tail of the slide still covers the reply's last lines).
                a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 0; a.toValue = 1
                a.beginTime = now + 0.25
                a.fillMode = .backwards
            } else {
                guard i < oldOffsets.count else { continue }
                let dy = (oldOffsets[i] - oldMinY) - (offsets[i] - minY)
                guard abs(dy) > 0.5 else { continue }
                a = CABasicAnimation(keyPath: "transform")
                a.fromValue = CATransform3DMakeTranslation(0, dy, 0)
                a.toValue = CATransform3DIdentity
            }
            a.duration = 0.25
            a.timingFunction = Motion.easeOut
            layer.add(a, forKey: "fold")
        }
    }

    // MARK: - Jump rail

    private func setUserRows(_ rows: [Int]) {
        guard rows != userRows else { return }
        userRows = rows
        jumpedTo = nil
        hideJumpList()                             // its rows point at the old list
        layoutRail()
    }

    /// Lines evenly spaced up from the bottom-left corner (newest lowest — nearest the input, where the mouse
    /// usually is); shown from two messages up (one has nowhere to jump).
    private func layoutRail() {
        let n = userRows.count
        rail.isHidden = n < 2
        if rail.isHidden { hideJumpList() }
        let spacing = ChatJumpRail.spacing(count: n, height: max(0, bounds.height - 24))
        let h = spacing * CGFloat(n) + 8
        rail.frame = NSRect(x: 2, y: 8, width: ChatJumpRail.width, height: h)
        rail.set(count: n, current: currentMessage())
    }

    /// The message you're reading: the last one you sent that starts above 40% of the way down the view (a jump
    /// lands it at 35%) — or, scrolled to the bottom, anywhere on screen (a short last reply can't scroll up that
    /// far). Right after a jump it's the one you picked, even when the scroll stopped short.
    private func currentMessage() -> Int? {
        guard !userRows.isEmpty, userRows.last! < offsets.count else { return nil }
        if let j = jumpedTo, userRows.indices.contains(j) { return j }
        let clip = scroll.contentView.bounds
        let atBottom = clip.maxY >= doc.frame.height - 40
        let line = (atBottom ? clip.maxY - 30 : clip.minY + clip.height * 0.4) - headerHeight
        var lo = 0, hi = userRows.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if offsets[userRows[mid]] <= line { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found ?? 0
    }

    /// Glide so the n-th message you sent sits a little above the middle (35% down — easier to read than the
    /// top edge), then blink its bubble. A long way
    /// off, it first snaps to a screen short of the target so the glide never lays out the whole chat between.
    func jump(toMessage n: Int) {
        hideJumpList()
        guard userRows.indices.contains(n), userRows[n] < offsets.count else { return }
        let clip = scroll.contentView
        let id = rowIDs[userRows[n]]
        let target = min(max(0, headerHeight + offsets[userRows[n]] - clip.bounds.height * 0.35),
                         max(0, doc.frame.height - clip.bounds.height))
        following = false
        jumpedTo = n
        rail.set(count: userRows.count, current: n)
        let from = clip.bounds.minY, span = clip.bounds.height
        if abs(target - from) > span * 2 { setScrollY(target + (target > from ? -span : span)) }
        jumpGliding = true
        jumpToken += 1
        let token = jumpToken
        Motion.animate(0.35, timing: Motion.easeInOut, { _ in
            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
        }, completion: { [weak self] in
            guard let self, self.jumpToken == token else { return }
            self.jumpGliding = false
            self.scroll.reflectScrolledClipView(clip)
            self.tile()
            self.following = clip.bounds.maxY >= self.doc.frame.height - 40
            self.jumpButton.isHidden = self.following
            self.live[id]?.flash()
            if clip.bounds.minY < 300, self.session?.canLoadEarlier == true { self.onLoadEarlier?() }
        })
    }

    /// Open on a short hover (passing the mouse over the edge shouldn't pop it), close once the mouse has
    /// left both the rail and the list — the gap lets it travel from one to the other.
    private func hoverChanged() {
        hoverWork?.cancel()
        let work: DispatchWorkItem
        if overRail || overList {
            guard !jumpList.isOpen, overRail else { return }
            work = DispatchWorkItem { [weak self] in if self?.overRail == true { self?.showJumpList() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        } else {
            work = DispatchWorkItem { [weak self] in
                guard let self, !self.overRail, !self.overList else { return }
                self.hideJumpList()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
        hoverWork = work
    }

    /// ⌘J: open with keyboard focus (selection on the message you're reading), or close.
    func toggleJumpListFromKeyboard() {
        if jumpList.isOpen { hideJumpList(); return }
        showJumpList(keyboard: true)
    }

    func showJumpList(keyboard: Bool = false) {
        guard !rail.isHidden, let session else { return }
        let items = session.items
        let previews = userRows.map { r -> String in
            guard r < rowIDs.count, let i = session.index(of: rowIDs[r]) else { return "" }
            let line = items[i].text.split(whereSeparator: \.isNewline).lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            return line ?? (items[i].images.isEmpty ? "(empty)" : "(image)")
        }
        // The whole height, beside the rail; the rows sit at the bottom, level with the lines.
        let x = rail.frame.maxX + 2
        jumpList.frame = NSRect(x: x, y: 0, width: max(160, min(ChatJumpList.maxWidth, bounds.width - x - 16)), height: bounds.height)
        jumpList.show(previews, current: currentMessage(), fontSize: style.size - 1, bottomInset: rail.frame.minY)
        jumpList.present()
        setRowCursors(off: true)
        // Keyboard-opened: the list takes the keys and hands focus back when it closes. A hover-opened list
        // leaves focus alone — your typing in the input isn't interrupted by moving the mouse.
        if keyboard, let w = window {
            jumpList.returnFocus = w.firstResponder
            jumpList.select(currentMessage() ?? userRows.count - 1)
            w.makeFirstResponder(jumpList)
        }
    }

    func hideJumpList() {
        hoverWork?.cancel()
        overList = false
        guard jumpList.isOpen else { return }
        jumpList.dismiss()
        setRowCursors(off: false)
        if window?.firstResponder === jumpList {
            window?.makeFirstResponder(jumpList.returnFocus.flatMap { ($0 as? NSView)?.window === window ? $0 : nil })
        }
        jumpList.returnFocus = nil
    }

    private func setRowCursors(off: Bool) {
        for v in live.values { v.cursorsOff = off }
        for v in pool { v.cursorsOff = off }
    }

    // MARK: - DEV harness

    /// Scroll the whole transcript top→bottom→top in fixed steps, forcing a display each step, and report
    /// per-frame times + any content-height change (a jump) — the regression check for scroll lag.
    func debugScrollBenchmark(step: CGFloat = 60) -> [String: Any] {
        let clip = scroll.contentView
        var frames: [Double] = []
        var jumps = 0
        let startHeight = doc.frame.height
        following = false
        var y: CGFloat = max(0, doc.frame.height - clip.bounds.height)
        let upward = true
        while upward ? y > 0 : y < doc.frame.height {
            y = max(0, y - step)
            let h0 = doc.frame.height
            let t0 = CACurrentMediaTime()
            clip.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(clip)
            tile()
            window?.displayIfNeeded()
            CATransaction.flush()
            frames.append((CACurrentMediaTime() - t0) * 1000)
            if abs(doc.frame.height - h0) > 0.5 { jumps += 1 }
        }
        frames.sort()
        func p(_ q: Double) -> Double { frames.isEmpty ? 0 : frames[min(frames.count - 1, Int(Double(frames.count) * q))] }
        scrollToBottom()
        return ["frames": frames.count, "p50ms": p(0.5), "p95ms": p(0.95), "p99ms": p(0.99), "maxMs": frames.last ?? 0,
                "heightJumps": jumps, "contentHeightChanged": abs(doc.frame.height - startHeight) > 0.5, "rows": heights.count,
                "liveRows": live.count, "pooledRows": pool.count]
    }

    func debugState() -> [String: Any] {
        let clip = scroll.contentView.bounds
        return ["rows": heights.count, "docHeight": Int(doc.frame.height), "scrollY": Int(clip.minY),
                "viewportH": Int(clip.height), "following": following, "jumpVisible": !jumpButton.isHidden,
                "pictureRows": live.values.compactMap { $0.debugPictures }, 
                "liveRows": live.count, "maxTileMs": maxTileMs, "headerHeight": Int(headerHeight),
                "emptyShown": !emptyLabel.isHidden, "preparing": preparing, "syncAfterPrepare": syncAfterPrepare,
                "cacheCount": cache.count, "measuredWidth": Int(measuredWidth), "rowWidth": Int(rowWidth),
                "rowViews": doc.subviews.filter { $0 is ChatRowView }.count,
                "shownRowViews": doc.subviews.filter { $0 is ChatRowView && !$0.isHidden }.count,
                "pool": pool.count, "railShown": !rail.isHidden, "railCount": rail.count, "railCurrent": rail.current ?? -1,
                "rowCursorsOff": (Array(live.values) + pool).filter(\.cursorsOff).count,
                "flashing": live.values.filter(\.isFlashing).map(\.itemID),
                "collapsed": collapsed.count,                 "foldAnim": live.values.compactMap { v -> [String: Any]? in
                    guard let l = v.layer, let a = l.animation(forKey: "fold") else { return nil }
                    return ["id": v.itemID, "key": (a as? CABasicAnimation)?.keyPath ?? "",
                            "modelY": Int(l.frame.minY), "shownY": Int(l.presentation()?.frame.minY ?? -1)] }, "hiddenRows": folds.filter { $0 == .hidden }.count,
                "jumpList": jumpList.isOpen ? jumpList.previews : [], "jumpListViewHidden": jumpList.isHidden, "jumpListFade": jumpList.debugFade,
                "jumpListSelected": jumpList.selected ?? -1, "jumpListFocused": window?.firstResponder === jumpList,
                "jumpListAlpha": Double(jumpList.layer?.presentation()?.opacity ?? jumpList.layer?.opacity ?? 0)]
    }

    /// Fold the n-th message you sent (as the chevron would; `all` = ⌥-click).
    func debugFold(_ n: Int, all: Bool) {
        guard userRows.indices.contains(n) else { return }
        toggleFold(rowIDs[userRows[n]], all: all)
        CATransaction.flush()     // commit now, so a dump in the same tick reads the animations' first frame
    }

    /// Fold the n-th message and record where each mounted row is actually drawn (presentation layer, in
    /// transcript-top coordinates) ~120×/s for half a second — the check for a fold animation that jumps.
    func debugFoldRecord(_ n: Int, path: String) {
        guard userRows.indices.contains(n) else { return }
        var frames: [[String: Any]] = []
        let t0 = CACurrentMediaTime()
        func sample() {
            let top = scroll.contentView.bounds.minY
            let rows = live.values.sorted { $0.frame.minY < $1.frame.minY }.map { v -> [String: Any] in
                let p = v.layer?.presentation() ?? v.layer
                let f = p?.frame ?? v.frame
                let y = f.minY - top                                   // row layers are top-down, like the views
                return ["id": v.itemID, "y": Double(y), "h": Double(f.height), "a": Double(p?.opacity ?? 1),
                        "modelY": Double(v.frame.minY - top)]
            }
            frames.append(["t": CACurrentMediaTime() - t0, "rows": rows])
        }
        sample()
        toggleFold(rowIDs[userRows[n]], all: false)
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { t in
            sample()
            if CACurrentMediaTime() - t0 > 0.5 {
                t.invalidate()
                if let d = try? JSONSerialization.data(withJSONObject: frames) { try? d.write(to: URL(fileURLWithPath: path)) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func debugScroll(toFraction f: CGFloat) {
        let clip = scroll.contentView
        following = false
        let y = max(0, doc.frame.height - clip.bounds.height) * f
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
        boundsChanged()
    }

    /// Press the n-th visible code block's Copy button (top to bottom); returns what it copied.
    func debugPressCopy(_ n: Int) -> String? {
        let rows = live.values.filter { $0.frame.intersects(scroll.contentView.bounds) }.sorted { $0.frame.minY < $1.frame.minY }
        let buttons = rows.flatMap { $0.copyButtons.filter { !$0.isHidden } }
        guard buttons.indices.contains(n) else { return nil }
        buttons[n].copyCode()
        return buttons[n].code
    }

    func debugCopyButtonCount() -> Int {
        live.values.filter { $0.frame.intersects(scroll.contentView.bounds) }.reduce(0) { $0 + $1.copyButtons.filter { !$0.isHidden }.count }
    }

    /// Selected text rendered in the visible rows (harness assertions on what the user actually sees).
    func debugVisibleText() -> String {
        live.sorted { $0.value.frame.minY < $1.value.frame.minY }
            .filter { $0.value.frame.intersects(scroll.contentView.bounds) }
            .map { $0.value.text }
            .joined(separator: "\n---\n")
    }
}

/// Flipped document view (rows lay out top-down).
final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// One transcript row: a selectable TextKit 1 text view plus the chrome drawn around it (user bubble,
/// the `⏺` gutter dot colored by tool status).
final class ChatRowView: NSView, NSTextViewDelegate {
    override var isFlipped: Bool { true }

    private let textView: ChatRowTextView
    private let bubble = CALayer()                  // user-message background
    private let dot = CALayer()                     // the ⏺ gutter dot (tool status color)
    private(set) var copyButtons: [ChatCopyButton] = []   // one per code block, top-right corner
    private var kind: ChatItem.Kind = .assistant
    private(set) var itemID = 0
    private var raw = ""
    var onToggle: ((Int) -> Void)?
    var onTypeAhead: ((NSEvent) -> Void)?
    var onFold: ((Int, Bool) -> Void)?              // item id, all (⌥)
    var onPicture: ((Int, Int) -> Void)?            // item id, image index
    /// Where a row's pictures are vs its text view — and what a hit test at each picture's centre finds.
    var debugPictures: [String: Any]? {
        let pics = textView.pictureFrames()
        guard !pics.isEmpty else { return nil }
        func r(_ x: NSRect) -> String { "\(Int(x.minX)),\(Int(x.minY)) \(Int(x.width))x\(Int(x.height))" }
        return ["row": r(bounds), "textView": r(textView.frame),
                "pictures": pics.map { i, f -> String in
                    let c = convert(NSPoint(x: f.midX, y: f.midY), from: textView)
                    let hit = superview.flatMap { hitTest(convert(c, to: $0)) }
                    return "\(i): \(r(f)) in text → hit \(hit.map { String(describing: type(of: $0)) } ?? "nil")"
                }]
    }

    func debugClickPicture(_ i: Int) -> Bool {
        guard textView.pictureFrames().contains(where: { $0.0 == i }) else { return false }
        textView.window?.makeFirstResponder(textView)
        onPicture?(itemID, i)
        return true
    }
    private let foldButton = PointerButton()       // ▾ / ▸ in the bubble's top-right (on hover, or while folded)
    private let stub = PointerButton()             // "Show Claude's reply" under a folded message
    private var fold = (collapsible: false, collapsed: false)
    private var hovering = false
    static let stubHeight: CGFloat = 26
    private var foldExtra: CGFloat { fold.collapsed ? Self.stubHeight : 0 }
    var text: String { textView.string }
    var cursorsOff: Bool { get { textView.cursorsOff } set { textView.cursorsOff = newValue } }

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.backgroundLayoutEnabled = false        // rows lay out on demand; idle background passes are waste
        textView = ChatRowTextView(frame: .zero, textContainer: container)   // TextKit 1 — matches ChatMeasurer
        super.init(frame: .zero)
        // Chrome is two small sublayers, not a draw(_:) — no row-sized backing store to repaint on every
        // height change while a reply streams.
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        bubble.cornerRadius = 8
        bubble.backgroundColor = Self.bubbleColor
        dot.cornerRadius = 3.5
        layer?.addSublayer(bubble)
        layer?.addSublayer(dot)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.delegate = self
        textView.onTypeAhead = { [weak self] e in self?.onTypeAhead?(e) }
        textView.copyWhole = { [weak self] in self?.raw ?? "" }
        textView.onPicture = { [weak self] i in if let self { self.onPicture?(self.itemID, i) } }
        addSubview(textView)
        for b in [foldButton, stub] {
            b.isBordered = false
            b.bezelStyle = .inline
            b.setButtonType(.momentaryChange)
            b.target = self
            b.action = #selector(foldTapped)
            b.isHidden = true
            addSubview(b)
        }
        foldButton.imagePosition = .imageOnly
        foldButton.contentTintColor = NSColor(white: 0.6, alpha: 1)
        foldButton.toolTip = "Collapse or expand Claude’s reply (⌥-click: all replies)"
        stub.toolTip = "Show Claude’s reply (⌥-click: all replies)"
        stub.alignment = .left
        textView.covered = { [weak self] p in
            guard let self else { return false }
            let local = self.convert(p, from: nil)
            return ([self.foldButton, self.stub] + self.copyButtons).contains { !$0.isHidden && $0.frame.contains(local) }
        }
    }

    /// Show the fold controls for this row: the chevron on hover (always while folded), the stub while folded.
    func setFold(_ f: (collapsible: Bool, collapsed: Bool)) {
        guard f != fold || foldButton.isHidden == shouldHideChevron(f) else { return }
        let grew = f.collapsed != fold.collapsed
        fold = f
        foldButton.image = NSImage(systemSymbolName: f.collapsed ? "chevron.right" : "chevron.down",
                                   accessibilityDescription: f.collapsed ? "Expand reply" : "Collapse reply")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        foldButton.isHidden = shouldHideChevron(f)
        stub.isHidden = !f.collapsed
        if f.collapsed {
            stub.attributedTitle = NSAttributedString(string: "▸  Show Claude’s reply", attributes: [
                .foregroundColor: NSColor(white: 0.55, alpha: 1), .font: NSFont.systemFont(ofSize: 12)])
        }
        if grew { resizeSubviews(withOldSize: bounds.size) }
        layoutFoldControls()
        if grew, f.collapsed, !Motion.reduceMotion {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0; a.toValue = 1; a.duration = 0.25
            stub.layer?.add(a, forKey: "fold")
        }
    }
    private func shouldHideChevron(_ f: (collapsible: Bool, collapsed: Bool)) -> Bool {
        kind != .user || !f.collapsible || !(hovering || f.collapsed)
    }
    private func layoutFoldControls() {
        guard kind == .user else { return }
        let col = ChatRowGeometry.column(bounds.width)
        foldButton.frame = NSRect(x: col.x + col.w - 30, y: 12 + 5, width: 24, height: 24)
        let top = bounds.height - foldExtra - 8 + 4
        stub.frame = NSRect(x: col.x + 12, y: top, width: 200, height: Self.stubHeight - 6)
    }
    @objc private func foldTapped() {
        onFold?(itemID, NSApp.currentEvent?.modifierFlags.contains(.option) == true)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self && $0.options.contains(.mouseEnteredAndExited) }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; foldButton.isHidden = shouldHideChevron(fold) }
    override func mouseExited(with event: NSEvent) { hovering = false; foldButton.isHidden = shouldHideChevron(fold) }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Show `item`. With `incremental` (the same streaming item again), only the text from the first
    /// changed paragraph on is replaced, so TextKit re-lays and repaints just the new lines instead of the
    /// whole message.
    func configure(_ item: ChatItem, cache attr: NSAttributedString, width: CGFloat, incremental: Bool = false) {
        let sameItem = item.id == itemID
        itemID = item.id
        kind = item.kind
        raw = item.kind == .tool ? (item.toolResult ?? "") : item.text
        let col = ChatRowGeometry.column(width)
        let ins = ChatRowGeometry.insets(item.kind)
        let tw = ChatRowGeometry.textWidth(item.kind, rowWidth: width)
        if textView.textContainer?.size.width != tw { textView.textContainer?.size = NSSize(width: tw, height: .greatestFiniteMagnitude) }
        if let storage = textView.textStorage {
            if incremental, sameItem { Self.replaceTail(storage, with: attr) } else { storage.setAttributedString(attr) }
        }
        textView.frame = NSRect(x: col.x + ins.left, y: ins.top, width: tw, height: max(1, bounds.height - ins.top - ins.bottom - foldExtra))
        layoutChrome(dotColor: Self.dot(for: item))
        layoutCopyButtons()
        if textView.hasPictures != !item.images.isEmpty || !item.images.isEmpty {
            textView.hasPictures = !item.images.isEmpty
            window?.invalidateCursorRects(for: textView)                    // the pictures' hand
        }
    }

    /// A Copy button in the top-right corner of every code block (tagged `.chatCode` by the renderer),
    /// positioned from the block's laid-out bounds. Buttons are reused across configures.
    private func layoutCopyButtons() {
        guard let storage = textView.textStorage, let lm = textView.layoutManager else { return }
        var blocks: [(NSRange, String)] = []
        if storage.length > 0 {
            storage.enumerateAttribute(.chatCode, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
                if let code = v as? String { blocks.append((r, code)) }
            }
        }
        while copyButtons.count < blocks.count {
            let b = ChatCopyButton()
            addSubview(b, positioned: .above, relativeTo: textView)
            copyButtons.append(b)
        }
        for (i, b) in copyButtons.enumerated() {
            guard i < blocks.count else { b.isHidden = true; continue }
            let (range, code) = blocks[i]
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: glyphs, in: textView.textContainer!)
            if let block = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.first {
                rect = lm.boundsRect(for: block, glyphRange: glyphs)
            }
            // 8pt in from the block's top-right corner; a one-line block gets it vertically centered.
            let side = ChatCopyButton.side, inset: CGFloat = 8
            let dy = min(inset - 2, max(0, (rect.height - side) / 2))
            b.frame = NSRect(x: textView.frame.minX + rect.maxX - side - inset, y: textView.frame.minY + rect.minY + dy,
                             width: side, height: side)
            b.code = code
            b.isHidden = false
        }
    }

    /// Replace `storage`'s content with `new`, touching only what changed: keep the longest common prefix of
    /// characters, backed off to the start of its last paragraph (a paragraph still streaming may restyle
    /// as it completes — a list item, a heading, a fence).
    static func replaceTail(_ storage: NSTextStorage, with new: NSAttributedString) {
        let old = storage.string as NSString, fresh = new.string as NSString
        let n = min(old.length, fresh.length)
        var i = 0
        while i < n, old.character(at: i) == fresh.character(at: i) { i += 1 }
        if i == old.length, i == fresh.length, storage.isEqual(to: new) { return }
        let keep = old.paragraphRange(for: NSRange(location: min(i, max(0, old.length - 1)), length: 0)).location
        let cut = min(keep, i)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: cut, length: old.length - cut),
                                  with: new.attributedSubstring(from: NSRange(location: cut, length: fresh.length - cut)))
        storage.endEditing()
    }

    private func layoutChrome(dotColor: NSColor?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let col = ChatRowGeometry.column(bounds.width)
        bubble.isHidden = kind != .user
        if kind == .user { bubble.frame = NSRect(x: col.x, y: 12, width: col.w, height: max(0, bounds.height - 12 - 8 - foldExtra)) }
        if let c = dotColor, kind != .user {
            let ins = ChatRowGeometry.insets(kind)
            let lineH = (textView.textStorage?.length ?? 0) > 0
                ? (textView.layoutManager?.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height ?? 16) : 16
            let d: CGFloat = kind == .assistant || kind == .tool ? 7 : 5
            let y = ins.top + max(0, (min(lineH, 22) - d) / 2)
            dot.frame = NSRect(x: col.x + 5 + (7 - d) / 2, y: y, width: d, height: d)
            dot.cornerRadius = d / 2
            dot.backgroundColor = c.cgColor
            dot.isHidden = false
        } else {
            dot.isHidden = true
        }
        CATransaction.commit()
    }

    /// Height of the text as this row's own (TextKit 1) text view lays it out — same stack as ChatMeasurer.
    func textHeight() -> CGFloat {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return 1 }
        lm.ensureLayout(for: tc)
        return ceil(max(lm.usedRect(for: tc).height, 1))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        endFlash(animated: false)
        fold = (false, false); hovering = false
        layer?.removeAnimation(forKey: "fold")
        foldButton.isHidden = true; stub.isHidden = true
    }

    private static let bubbleColor = NSColor(white: 0.175, alpha: 1).cgColor
    private static let flashColor = NSColor(srgbRed: 0.20, green: 0.33, blue: 0.55, alpha: 1).cgColor
    private var flashToken = 0
    private(set) var isFlashing = false

    /// Blink the bubble twice over ~2 s — the message a jump landed on.
    func flash() {
        guard kind == .user else { return }
        flashToken += 1
        let token = flashToken
        isFlashing = true
        setBubble(Self.flashColor, fade: 0.15)
        let steps: [(TimeInterval, CGColor?)] = [(0.65, Self.bubbleColor), (1.0, Self.flashColor), (1.65, nil)]
        for (t, color) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self, self.flashToken == token else { return }   // reused or re-flashed since
                if let color { self.setBubble(color, fade: 0.25) } else { self.endFlash(animated: true) }
            }
        }
    }

    private func endFlash(animated: Bool) {
        flashToken += 1
        guard isFlashing else { return }
        isFlashing = false
        setBubble(Self.bubbleColor, fade: animated ? 0.4 : 0)
    }

    private func setBubble(_ color: CGColor, fade: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(fade)
        CATransaction.setDisableActions(fade == 0)
        bubble.backgroundColor = color
        CATransaction.commit()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        let ins = ChatRowGeometry.insets(kind)
        var f = textView.frame
        f.size.height = max(1, bounds.height - ins.top - ins.bottom - foldExtra)
        textView.frame = f
        if !copyButtons.isEmpty { layoutCopyButtons() }
        if kind == .user {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let col = ChatRowGeometry.column(bounds.width)
            bubble.frame = NSRect(x: col.x, y: 12, width: col.w, height: max(0, bounds.height - 12 - 8 - foldExtra))
            CATransaction.commit()
            layoutFoldControls()
        }
    }

    private static func dot(for item: ChatItem) -> NSColor? {
        switch item.kind {
        case .assistant: return NSColor(white: 0.85, alpha: 1)
        case .tool:
            switch item.toolStatus {
            case .running: return item.streaming ? ChatStyle.faint : ChatStyle.amber
            case .waiting: return ChatStyle.amber
            case .done: return ChatStyle.green
            case .failed, .denied: return ChatStyle.red
            case .interrupted: return ChatStyle.faint
            }
        case .thinking: return ChatStyle.faint
        case .error: return ChatStyle.red
        default: return nil
        }
    }

    // Link clicks: our toggle scheme expands/collapses; web links open in the browser.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url else { return false }
        if url.scheme == "multee-chat" {
            if url.host == "toggle" { onToggle?(itemID) }
            return true
        }
        NSWorkspace.shared.open(url)
        return true
    }
}

/// The copy icon on a code block: icon only, brightens (with a faint backing) on hover, flips to a green
/// checkmark for a moment after copying.
final class ChatCopyButton: PointerButton {
    var code = ""
    static let side: CGFloat = 24
    private var resetWork: DispatchWorkItem?
    private var tracking: NSTrackingArea?
    private var hovering = false
    private var copied = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = 6
        toolTip = "Copy code"
        target = self
        action = #selector(copyCode)
        refresh()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    private func refresh() {
        image = NSImage(systemSymbolName: copied ? "checkmark" : "doc.on.doc", accessibilityDescription: copied ? "Copied" : "Copy")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        contentTintColor = copied ? ChatStyle.green : NSColor(white: hovering ? 0.92 : 0.55, alpha: 1)
        layer?.backgroundColor = hovering ? NSColor(white: 1, alpha: 0.09).cgColor : NSColor.clear.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }

    @objc func copyCode() {
        Clipboard.copy(code)
        copied = true
        toolTip = "Copied"
        refresh()
        resetWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.copied = false; self?.toolTip = "Copy code"; self?.refresh() }
        resetWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: w)
    }
}

/// The row's text view: selectable, never editable. Typing while it has focus goes to the chat input (so
/// selecting text doesn't strand the keyboard); the context menu adds "Copy Message".
extension NSCursor {
    /// Over an image that opens in Quick Look: macOS's own zoom-in cursor (15+), looked up at runtime — the
    /// release build compiles against an older SDK that doesn't declare it — else a drawn magnifier.
    static let chatPreview: NSCursor = {
        let sel = NSSelectorFromString("zoomInCursor")
        if NSCursor.responds(to: sel), let c = NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor { return c }
        let size = NSSize(width: 18, height: 18)
        guard let symbol = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium)) else { return .pointingHand }
        let image = NSImage(size: size, flipped: false) { r in
            // A white halo so it reads on the dark transcript and on light screenshots alike.
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] as [(CGFloat, CGFloat)] {
                symbol.tinted(.white).draw(in: r.offsetBy(dx: dx, dy: dy).insetBy(dx: 1, dy: 1))
            }
            symbol.tinted(.black).draw(in: r.insetBy(dx: 1, dy: 1))
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 7, y: 7))
    }()
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { r in
            self.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
    }
}

final class ChatRowTextView: NSTextView {
    var onTypeAhead: ((NSEvent) -> Void)?
    var copyWhole: (() -> String)?
    var onPicture: ((Int) -> Void)?
    var hasPictures = false         // set per item — spares every mouse move over a text row the attribute scan

    /// The sent images in this row (tagged `.chatPicture` by the renderer): index and frame in this view.
    func pictureFrames() -> [(Int, NSRect)] {
        guard hasPictures, let storage = textStorage, storage.length > 0, let lm = layoutManager, let tc = textContainer
        else { return [] }
        var out: [(Int, NSRect)] = []
        storage.enumerateAttribute(.chatPicture, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            guard let i = v as? Int else { return }
            let glyphs = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            out.append((i, rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)))
        }
        return out
    }

    private func picture(at windowPoint: NSPoint) -> Int? {
        let p = convert(windowPoint, from: nil)
        return pictureFrames().first { $0.1.contains(p) }?.0
    }

    /// A rich-text NSTextView claims Quick Look for itself (it would preview its selected attachments — none,
    /// so an empty panel) and sits before the chat in the responder chain once a click makes it first
    /// responder. Decline, so the panel reaches `ChatViewController` and shows the message's full images.
    /// (The message box is plain text, which already declines — why the `[Image #n]` preview worked.)
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { false }

    /// A click on a sent image opens it in Quick Look (instead of selecting the attachment character).
    override func mouseDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.clickCount == 1, mods.isEmpty, let i = picture(at: event.locationInWindow) {
            window?.makeFirstResponder(self)        // Quick Look looks for its controller up this responder chain
            onPicture?(i)
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Printable keys (and Esc) go to the input; navigation/selection keys and shortcuts stay here.
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) || mods.contains(.control) || event.specialKey != nil { super.keyDown(with: event); return }
        onTypeAhead?(event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let item = NSMenuItem(title: "Copy Message", action: #selector(copyMessage), keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func copyMessage() {
        let s = copyWhole?() ?? string
        Clipboard.copy(s.isEmpty ? string : s)
    }

    // Scrolling belongs to the transcript, not this (non-scrolling) text view.
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }

    /// Off while something floats over the transcript (the jump list): cursor rects and tracking areas
    /// ignore what's on top, so the I-beam would fight the overlay's own cursor on every mouse move.
    var cursorsOff = false {
        didSet { if oldValue != cursorsOff { window?.invalidateCursorRects(for: self) } }
    }
    /// Whether a button of the row (fold chevron, copy) sits over this window point. NSTextView sets the I-beam
    /// from its own tracking area on every enter/move (`_mouseInside:`), button on top or not — traced as the
    /// hand/I-beam flicker over the ▾.
    var covered: ((NSPoint) -> Bool)?
    private func quiet(_ e: NSEvent) -> Bool { cursorsOff || covered?(e.locationInWindow) == true }
    /// Over a picture, this view's own tracking-area events set the magnifier — a cursor rect alone never got a
    /// turn (the text view picks its cursor from its tracking area on every move, and staying quiet there
    /// left AppKit's arrow; traced with `cursorTrace`).
    private func pictureCursor(_ e: NSEvent) -> Bool {
        guard !cursorsOff, picture(at: e.locationInWindow) != nil else { return false }
        NSCursor.chatPreview.set()
        return true
    }
    override func resetCursorRects() {
        guard !cursorsOff else { return }
        super.resetCursorRects()
        // A picture scrolled out of view while its row is still on screen intersects to `.null` (an infinite
        // origin), which `addCursorRect` rejects with an exception that kills the app — skip it.
        for (_, r) in pictureFrames() {
            let shown = r.intersection(visibleRect)
            if !shown.isEmpty { addCursorRect(shown, cursor: .chatPreview) }
        }
    }
    override func cursorUpdate(with event: NSEvent) {
        if !pictureCursor(event), !quiet(event) { super.cursorUpdate(with: event) }
    }
    override func mouseMoved(with event: NSEvent) {
        if !pictureCursor(event), !quiet(event) { super.mouseMoved(with: event) }
    }
    override func mouseEntered(with event: NSEvent) {
        if !pictureCursor(event), !quiet(event) { super.mouseEntered(with: event) }
    }
}

/// The strip at the top of the transcript: "Load earlier messages" / loading spinner.
final class ChatHistoryHeader: NSView {
    enum State { case none, more, loading }
    private let button = PointerButton()
    private let spinner = NSProgressIndicator()
    var onLoad: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.title = "Load earlier messages"
        button.isBordered = false
        button.contentTintColor = ChatStyle.link
        button.font = .systemFont(ofSize: 12)
        button.target = self
        button.action = #selector(tapped)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(button)
        addSubview(spinner)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func set(_ s: State) {
        button.isHidden = s != .more
        if s == .loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        button.sizeToFit()
        button.frame.origin = NSPoint(x: (bounds.width - button.frame.width) / 2, y: (bounds.height - button.frame.height) / 2)
        spinner.frame = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    @objc private func tapped() { onLoad?() }
}
