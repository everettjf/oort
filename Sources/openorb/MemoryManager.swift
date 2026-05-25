import Foundation
import Virtualization

/// Stage M3: active memory ballooning — return idle guest memory to macOS.
///
/// VZ lets us set a balloon "target" size; the guest balloon driver inflates to
/// hand pages back to the host (or deflates to reclaim them). Left alone, the
/// VM's host footprint only ever grows (freed guest pages stay resident). This
/// periodically reads the guest's real usage (over the vsock agent) and sets the
/// target to `used + headroom`, so the host footprint tracks what the guest
/// actually needs — OrbStack-style dynamic memory.
final class MemoryManager {
    private let device: VZVirtioTraditionalMemoryBalloonDevice
    private let vmQueue: DispatchQueue
    private weak var socketDevice: VZVirtioSocketDevice?
    private let agentPort: UInt32
    private let configuredBytes: UInt64
    private let minBytes: UInt64 = 512 * 1024 * 1024
    private let headroomBytes: UInt64 = 384 * 1024 * 1024
    private let interval: TimeInterval = 20

    init(device: VZVirtioTraditionalMemoryBalloonDevice, vmQueue: DispatchQueue,
         socketDevice: VZVirtioSocketDevice, configuredBytes: UInt64, agentPort: UInt32 = 2376) {
        self.device = device
        self.vmQueue = vmQueue
        self.socketDevice = socketDevice
        self.configuredBytes = configuredBytes
        self.agentPort = agentPort
    }

    func start() {
        Log.info("memory: active ballooning on (target tracks guest usage + headroom)")
        Thread.detachNewThread { [weak self] in self?.loop() }
    }

    private func loop() {
        while true {
            Thread.sleep(forTimeInterval: interval)
            guard let (total, available) = queryGuestMemory() else { continue }
            let used = total > available ? total - available : total
            var target = used + headroomBytes
            target = min(max(target, minBytes), configuredBytes)
            // Round to MiB; VZ expects a sane value ≤ configured size.
            target = (target / (1024 * 1024)) * (1024 * 1024)
            Log.info("memory: guest using \(used/(1024*1024))MiB → balloon target \(target/(1024*1024))MiB (cap \(configuredBytes/(1024*1024))MiB)")
            vmQueue.async { [weak self] in
                self?.device.targetVirtualMachineMemorySize = target
            }
        }
    }

    /// Ask the guest agent for MemTotal/MemAvailable (in bytes).
    private func queryGuestMemory() -> (total: UInt64, available: UInt64)? {
        guard let resp = agentExec("grep -E '^(MemTotal|MemAvailable):' /proc/meminfo") else { return nil }
        var total: UInt64?, available: UInt64?
        for line in resp.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).filter { !$0.isEmpty }
            guard parts.count >= 2, let kb = UInt64(parts[1]) else { continue }
            if line.hasPrefix("MemTotal:") { total = kb * 1024 }
            if line.hasPrefix("MemAvailable:") { available = kb * 1024 }
        }
        if let t = total, let a = available { return (t, a) }
        return nil
    }

    /// Run a command on the guest via the vsock exec agent and return its output.
    private func agentExec(_ cmd: String) -> String? {
        let sem = DispatchSemaphore(value: 0)
        var fd: Int32 = -1
        vmQueue.async { [weak self] in
            guard let self, let dev = self.socketDevice else { sem.signal(); return }
            dev.connect(toPort: self.agentPort) { result in
                if case .success(let conn) = result { fd = dup(conn.fileDescriptor) }
                sem.signal()
            }
        }
        sem.wait()
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let body = Array(cmd.utf8)
        let req = "POST / HTTP/1.0\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n\(cmd)"
        _ = req.withCString { write(fd, $0, strlen($0)) }
        var data = Data()
        let n = 16 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 1)
        defer { buf.deallocate() }
        while true { let r = read(fd, buf, n); if r <= 0 { break }; data.append(Data(bytes: buf, count: r)) }
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return String(data: data.subdata(in: sep.upperBound..<data.endIndex), encoding: .utf8)
    }
}
