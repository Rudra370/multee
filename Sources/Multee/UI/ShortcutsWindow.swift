import AppKit

/// The keyboard shortcuts Multee supports, grouped — shown in the shortcuts panel (bottom-bar keyboard icon).
/// Keep in sync with the menu (`AppDelegate.buildMenu`) and the ⌘+/− monitor.
enum Shortcuts {
    struct Item { let name: String; let keys: String }
    struct Section { let title: String; let items: [Item] }

    static let sections: [Section] = [
        Section(title: "General", items: [
            Item(name: "Open Folder…", keys: "⌘O"),
            Item(name: "Settings…", keys: "⌘,"),
            Item(name: "Close Tab", keys: "⌘W"),
            Item(name: "Quit Multee", keys: "⌘Q"),
        ]),
        Section(title: "Navigation", items: [
            Item(name: "Go to File…", keys: "⌘P"),
            Item(name: "Command Palette…", keys: "⌘⇧P"),
            Item(name: "Find in Files…", keys: "⌘⇧F"),
        ]),
        Section(title: "Editing", items: [
            Item(name: "Save", keys: "⌘S"),
            Item(name: "Format Document", keys: "⇧⌥F"),
            Item(name: "Undo", keys: "⌘Z"),
            Item(name: "Redo", keys: "⌘⇧Z"),
            Item(name: "Cut", keys: "⌘X"),
            Item(name: "Copy", keys: "⌘C"),
            Item(name: "Paste", keys: "⌘V"),
            Item(name: "Select All", keys: "⌘A"),
        ]),
        Section(title: "Find in File", items: [
            Item(name: "Find…", keys: "⌘F"),
            Item(name: "Find Next", keys: "⌘G"),
            Item(name: "Find Previous", keys: "⌘⇧G"),
            Item(name: "Find and Replace…", keys: "⌥⌘F"),
            Item(name: "Use Selection for Find", keys: "⌘E"),
        ]),
        Section(title: "View", items: [
            Item(name: "Increase Font Size", keys: "⌘+"),
            Item(name: "Decrease Font Size", keys: "⌘−"),
        ]),
    ]
}

/// One key rendered as a small rounded "keycap".
private final class KeycapView: NSView {
    init(_ char: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)            // don't stretch to fill the row
        setContentCompressionResistancePriority(.required, for: .horizontal)
        let label = NSTextField(labelWithString: char)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor(white: 0.92, alpha: 1)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 19),
            widthAnchor.constraint(equalToConstant: 22),     // fixed — all our keys are single glyphs (⌘⇧⌥ + 1 char)
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// Borderless-Esc helper button: a hidden button whose key equivalent is Escape closes the window.
private final class ShortcutsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The "Keyboard Shortcuts" panel — opened from the bottom bar's keyboard icon. A dark, scrollable list of
/// `Shortcuts.sections`, each row = command name + keycap chips. Esc or the close button dismisses it.
final class ShortcutsWindowController: NSWindowController {
    static let shared = ShortcutsWindowController()

    private init() {
        let panel = ShortcutsPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 580),
                                   styleMask: [.titled, .closable, .utilityWindow],
                                   backing: .buffered, defer: false)
        panel.title = "Keyboard Shortcuts"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        buildContent(in: panel)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func closeWindow() { window?.close() }

    private func buildContent(in panel: NSPanel) {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor

        let stack = NSStackView(views: Shortcuts.sections.map(Self.sectionView))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = stack
        root.addSubview(scroll)

        // Hidden Esc → close.
        let esc = NSButton(); esc.isHidden = true; esc.keyEquivalent = "\u{1b}"
        esc.target = self; esc.action = #selector(closeWindow)
        root.addSubview(esc)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])
        panel.contentView = root
    }

    // MARK: - Builders

    private static func sectionView(_ section: Shortcuts.Section) -> NSView {
        let header = NSTextField(labelWithString: section.title.uppercased())
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = NSColor(white: 0.5, alpha: 1)

        let rows = NSStackView(views: [header] + section.items.map(Self.rowView))
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 7
        return rows
    }

    private static func rowView(_ item: Shortcuts.Item) -> NSView {
        let name = NSTextField(labelWithString: item.name)
        name.font = .systemFont(ofSize: 13)
        name.textColor = NSColor(white: 0.9, alpha: 1)
        name.translatesAutoresizingMaskIntoConstraints = false

        // Chips chained left→right by hand (NSStackView stretches the first chip to fill).
        let caps = NSView()
        caps.translatesAutoresizingMaskIntoConstraints = false
        var prev: NSView?
        for ch in item.keys {
            let cap = KeycapView(String(ch))
            caps.addSubview(cap)
            cap.topAnchor.constraint(equalTo: caps.topAnchor).isActive = true
            cap.bottomAnchor.constraint(equalTo: caps.bottomAnchor).isActive = true
            cap.leadingAnchor.constraint(equalTo: prev?.trailingAnchor ?? caps.leadingAnchor,
                                         constant: prev == nil ? 0 : 3).isActive = true
            prev = cap
        }
        prev?.trailingAnchor.constraint(equalTo: caps.trailingAnchor).isActive = true

        // Name pinned left, keycaps pinned right at natural width (no stretching).
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(name); row.addSubview(caps)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: 460 - 44),   // panel width − insets
            row.heightAnchor.constraint(equalToConstant: 22),
            name.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            caps.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            caps.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: caps.leadingAnchor, constant: -10),
        ])
        return row
    }

    /// Render the panel content to a PNG for design verification (the panel is a separate window the
    /// screenshot harness can't grab unless it's key).
    func debugRender(to path: String) {
        guard let root = window?.contentView,
              let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.layoutSubtreeIfNeeded()
        root.cacheDisplay(in: root.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
