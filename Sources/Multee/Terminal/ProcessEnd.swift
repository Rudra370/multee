import Foundation

/// Ending what a tab was running.
///
/// SwiftTerm's `terminate()` sends `SIGTERM` to the child alone — and an interactive shell (or Claude)
/// **ignores SIGTERM**. Measured on a four-day-old Multee: nine `<defunct>` children and a dozen shells
/// that outlived their tabs, each still holding the pseudo-terminal file descriptor Multee leaked with it
/// (closing a tab raised the app's open-PTY count and never lowered it).
///
/// A hangup is what closing a terminal actually means, and it goes to the whole process **group**, so the
/// `node` processes Claude started go with it. Once the child is gone the terminal's descriptor sees EOF
/// and closes itself — the leak needs no separate fix. What does need one is the reap: SwiftTerm cancels
/// the monitor that would have called `waitpid`, so an exited child stays `<defunct>` until Multee quits.
enum ProcessEnd {
    /// Hang up now; anything still running a moment later is killed outright, then reaped.
    static func end(_ pid: pid_t) {
        guard pid > 1 else { return }
        send(SIGHUP, to: pid)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
            if waitpid(pid, nil, WNOHANG) == 0 { send(SIGKILL, to: pid) }   // 0 = still running
            reap(pid, tries: 20)
        }
    }

    /// The same for app quit, where no timer of ours will ever fire: hang up, wait briefly for them to go,
    /// kill whatever is left. No reaping — once we exit, the children are launchd's to clean up.
    static func endBeforeQuit(_ pids: [pid_t], grace: TimeInterval = 0.4) {
        var pending = pids.filter { $0 > 1 }
        guard !pending.isEmpty else { return }
        pending.forEach { send(SIGHUP, to: $0) }
        let deadline = Date().addingTimeInterval(grace)
        while !pending.isEmpty, Date() < deadline {
            usleep(20_000)
            pending = pending.filter { waitpid($0, nil, WNOHANG) == 0 }
        }
        pending.forEach { send(SIGKILL, to: $0) }
    }

    /// A pseudo-terminal's child leads its own process group, so signal the group and its children go with
    /// it. Anything else gets the signal alone.
    ///
    /// The `pid > 1` guard is load-bearing: `kill(-1, …)` signals *every* process the user owns.
    private static func send(_ sig: Int32, to pid: pid_t) {
        guard pid > 1 else { return }
        _ = kill(getpgid(pid) == pid ? -pid : pid, sig)
    }

    /// Collect the exit status the kernel holds until someone asks for it — the `<defunct>` row.
    private static func reap(_ pid: pid_t, tries: Int) {
        guard tries > 0, waitpid(pid, nil, WNOHANG) == 0 else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { reap(pid, tries: tries - 1) }
    }
}
