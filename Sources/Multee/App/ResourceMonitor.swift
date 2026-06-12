import Foundation
import Darwin

/// Samples this process's own memory footprint and CPU% (the same numbers Activity Monitor shows for
/// the Multee process — not its Claude children, which are separate processes). Cheap: two syscalls
/// every 2s. Used to surface live resource usage in the title bar.
final class ResourceMonitor {
    var onUpdate: ((_ memoryMB: Double, _ cpuPercent: Double) -> Void)?

    private var timer: Timer?
    private var lastCPU: Double = 0
    private var lastWall = Date()

    func start() {
        lastCPU = Self.cpuSeconds()
        lastWall = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        let now = Date()
        let cpuNow = Self.cpuSeconds()
        let dtWall = now.timeIntervalSince(lastWall)
        let dtCPU = cpuNow - lastCPU
        lastWall = now
        lastCPU = cpuNow
        let pct = dtWall > 0 ? max(0, dtCPU / dtWall * 100) : 0
        onUpdate?(Self.memoryMB(), pct)
    }

    /// phys_footprint — matches Activity Monitor's "Memory" column.
    static func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// Cumulative CPU seconds (user + system) across all live threads of this task.
    static func cpuSeconds() -> Double {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var total: Double = 0
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var ic = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.stride / MemoryLayout<integer_t>.stride)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(ic)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &ic)
                }
            }
            if kr == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
                total += Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
            }
        }
        return total
    }
}
