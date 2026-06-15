import AppKit
import Combine

/// One git poller per open repo, shared by the file tree and the Changes panel — the single source of
/// truth for both, plus the git mutation actions. A single FSEvents watcher + fallback timer drives
/// one debounced poll; each consumer's data is fetched only while it is the visible sidebar mode (so
/// we never compute Changes data while the tree is showing, or vice-versa). This replaces the two
/// independent watchers/polls the two views used to own (and the on-open double-poll quirk that came
/// with them). See DECISIONS.md D19.
///
/// `RepoWatcher` already delivers `onChange` on the main thread, so polling and the signature fields
/// below are all touched on main — no locking needed.
final class RepoStore: ObservableObject {
    let repo: String
    private let settings: Settings

    @Published private(set) var files: [FileEntry] = []      // file tree (full listing + status)
    @Published private(set) var staged: [FileEntry] = []     // Changes — staged (index)
    @Published private(set) var unstaged: [FileEntry] = []   // Changes — unstaged (worktree)
    @Published private(set) var stashCount = 0
    @Published private(set) var branch: String?              // current branch (for the status bar)

    private var watcher: RepoWatcher?
    private var fallbackTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var treeSig = ""
    private var changesSig = ""
    private var treeActive = false
    private var changesActive = false

    init(repo: String, settings: Settings) {
        self.repo = repo
        self.settings = settings
        // Toggling "show gitignored folders" changes the tree's file set → re-poll the tree.
        settings.$expandIgnored.dropFirst().sink { [weak self] _ in
            self?.treeSig = ""
            self?.pollTree()
        }.store(in: &cancellables)
    }

    // MARK: Lifecycle

    /// Begin (or resume) watching. `tree` / `changes` say which consumer is currently visible — only
    /// that one is polled. Safe to call repeatedly (e.g. on every sidebar-mode toggle / app activate).
    func start(tree: Bool, changes: Bool) {
        setActive(tree: tree, changes: changes)
        pollBranch()   // show the branch immediately, not only after the first FS event
        if watcher == nil { watcher = RepoWatcher(path: repo) { [weak self] in self?.poll() } }
        watcher?.start()
        fallbackTimer?.invalidate()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() { watcher?.stop(); fallbackTimer?.invalidate(); fallbackTimer = nil }
    deinit { stop() }

    /// Switch which consumer is visible and immediately fetch the newly-shown one.
    func setActive(tree: Bool, changes: Bool) {
        treeActive = tree
        changesActive = changes
        if tree { pollTree() }
        if changes { pollChanges() }
    }

    // MARK: Polling (only the active consumers)

    private func poll() {
        pollBranch()   // cheap; always read (independent of which sidebar mode is visible)
        if treeActive { pollTree() }
        if changesActive { pollChanges() }
    }

    private func pollBranch() {
        let repo = self.repo
        DispatchQueue.global().async { [weak self] in
            let b = Git.branch(repo)
            DispatchQueue.main.async {
                guard let self, b != self.branch else { return }
                self.branch = b
            }
        }
    }

    private func pollTree() {
        let repo = self.repo, expand = settings.expandIgnored, prev = treeSig
        DispatchQueue.global().async { [weak self] in
            let files = Git.repoFiles(repo, expandIgnored: expand)
            let sig = files.map { "\($0.path)|\($0.status.rawValue)|\($0.isDir)" }.joined(separator: "\n")
            guard sig != prev else { return }   // unchanged → skip the publish (and the tree rebuild)
            DispatchQueue.main.async {
                guard let self, sig != self.treeSig else { return }
                self.treeSig = sig
                self.files = files
            }
        }
    }

    private func pollChanges() {
        let repo = self.repo, prev = changesSig
        DispatchQueue.global().async { [weak self] in
            let g = Git.statusGroups(repo)
            let stash = Git.stashCount(repo)
            let sig = (g.staged + g.unstaged).map { "\($0.path)|\($0.status.rawValue)" }.joined(separator: "\n")
                + "#staged:\(g.staged.count)#stash:\(stash)"
            guard sig != prev else { return }
            DispatchQueue.main.async {
                guard let self, sig != self.changesSig else { return }
                self.changesSig = sig
                self.staged = g.staged
                self.unstaged = g.unstaged
                self.stashCount = stash
            }
        }
    }

    /// Force the visible consumers to re-poll (after a git mutation, where FSEvents may lag).
    func refreshNow() {
        treeSig = ""
        changesSig = ""
        poll()
    }

    // MARK: Git mutations (Changes panel) — run off-main, then re-poll

    private func act(_ body: @escaping () -> Void) {
        DispatchQueue.global().async { body(); DispatchQueue.main.async { [weak self] in self?.refreshNow() } }
    }
    func stage(_ p: String)   { act { Git.stage(self.repo, p) } }
    func unstage(_ p: String) { act { Git.unstage(self.repo, p) } }
    func stageAll()           { act { Git.stageAll(self.repo) } }
    func unstageAll()         { act { Git.unstageAll(self.repo) } }
    func discard(_ f: FileEntry) { act { Git.discard(self.repo, f.path, f.status) } }
    func discardAll()         { act { Git.discardAll(self.repo) } }
    func stash()              { act { Git.stash(self.repo) } }
    func unstash()            { act { Git.unstash(self.repo) } }
    func commit(_ msg: String, all: Bool) { act { if all { Git.stageAll(self.repo) }; Git.commit(self.repo, msg) } }
    func commitPush(_ msg: String, all: Bool) { act { if all { Git.stageAll(self.repo) }; Git.commit(self.repo, msg); Git.push(self.repo) } }
}
