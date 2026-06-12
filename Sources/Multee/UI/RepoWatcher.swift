import Foundation

/// Watches a repo directory tree with FSEvents and fires `onChange` (coalesced + debounced) only
/// when files actually change — replacing the constant 1.5s git polling. When nothing changes, it
/// does nothing, so idle CPU is ~0 even with the app in the foreground.
final class RepoWatcher {
    private let path: String
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var debounce: DispatchWorkItem?

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue().fired()
        }
        // 0.4s latency lets FSEvents coalesce bursts (saves, builds) into one callback. FileEvents
        // flag = per-file granularity; covers .git/ changes (staging/commits) too.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx,
                                          [path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          0.4, flags) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        debounce?.cancel(); debounce = nil
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        stream = nil
    }

    private func fired() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.onChange() }
            self.debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
    }

    deinit { stop() }
}
