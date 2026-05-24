import Foundation
import Virtualization

/// Projects the guest Docker daemon onto a macOS Unix socket.
///
/// Flow per client connection:
///   docker CLI → unix:~/.openorb/docker.sock  (this AF_UNIX listener)
///             → VZVirtioSocketDevice.connect(toPort:)  (host→guest vsock)
///             → socat VSOCK-LISTEN:2375 → /run/docker.sock  (inside guest)
///
/// We splice the two file descriptors with a pair of blocking relay threads.
final class DockerSocketProxy {
    private let socketPath: String
    private let guestPort: UInt32
    private let vmQueue: DispatchQueue
    private weak var socketDevice: VZVirtioSocketDevice?

    private var listenFD: Int32 = -1
    private let lock = NSLock()
    /// Keep guest connections alive for the lifetime of each tunnel; the
    /// connection owns the underlying fd, so dropping it would close the socket.
    private var liveConnections = Set<VZVirtioSocketConnectionBox>()

    init(socketPath: String, guestPort: UInt32, vmQueue: DispatchQueue, socketDevice: VZVirtioSocketDevice) {
        self.socketPath = socketPath
        self.guestPort = guestPort
        self.vmQueue = vmQueue
        self.socketDevice = socketDevice
    }

    // MARK: - Listener

    func start() throws {
        try prepareSocketFile()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIError.runtime("socket() failed: \(errnoString())") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw CLIError.runtime("socket path too long: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else {
            close(fd)
            throw CLIError.runtime("bind(\(socketPath)) failed: \(errnoString())")
        }
        guard listen(fd, 128) == 0 else {
            close(fd)
            throw CLIError.runtime("listen() failed: \(errnoString())")
        }
        chmod(socketPath, 0o600)
        listenFD = fd

        Log.info("docker socket projected at unix://\(socketPath) → guest vsock:\(guestPort)")
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    private func prepareSocketFile() throws {
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: socketPath) {
            try FileManager.default.removeItem(atPath: socketPath)
        }
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                Log.warn("accept() failed: \(errnoString())")
                break
            }
            handleClient(client)
        }
    }

    // MARK: - Per-connection tunnel

    private func handleClient(_ clientFD: Int32) {
        // VZ requires socket-device calls on the VM's queue.
        vmQueue.async { [weak self] in
            guard let self, let device = self.socketDevice else { close(clientFD); return }
            device.connect(toPort: self.guestPort) { result in
                switch result {
                case .failure(let err):
                    Log.warn("vsock connect to port \(self.guestPort) failed: \(err.localizedDescription)")
                    close(clientFD)
                case .success(let connection):
                    self.bridge(clientFD: clientFD, connection: connection)
                }
            }
        }
    }

    private func bridge(clientFD: Int32, connection: VZVirtioSocketConnection) {
        // Dup the guest fd so our relay owns its lifetime independently of `connection`.
        let guestFD = dup(connection.fileDescriptor)
        guard guestFD >= 0 else {
            Log.warn("dup(guest fd) failed: \(errnoString())")
            close(clientFD)
            return
        }

        let box = VZVirtioSocketConnectionBox(connection)
        lock.lock(); liveConnections.insert(box); lock.unlock()

        // When EITHER direction finishes (EOF or error), tear down BOTH fds so
        // the other relay's blocking read() is woken immediately. Without this,
        // an HTTP keep-alive peer that never sends EOF would leave one relay
        // blocked forever, leaking the fd and the vsock connection — which
        // eventually exhausts the virtio-socket device and wedges the proxy.
        let teardownOnce = OnceFlag()
        let teardown = {
            teardownOnce.run {
                shutdown(clientFD, SHUT_RDWR)
                shutdown(guestFD, SHUT_RDWR)
            }
        }

        let done = DispatchGroup()
        done.enter(); done.enter()

        relay(from: clientFD, to: guestFD) { teardown(); done.leave() }   // CLI → guest
        relay(from: guestFD, to: clientFD) { teardown(); done.leave() }   // guest → CLI

        done.notify(queue: .global()) { [weak self] in
            close(clientFD)
            close(guestFD)
            self?.lock.lock(); self?.liveConnections.remove(box); self?.lock.unlock()
        }
    }

    /// Copy bytes one direction until EOF/error, then run `onClose` (which tears
    /// down both fds). Full-duplex teardown — not a half-close — so neither relay
    /// can block indefinitely on a keep-alive connection.
    private func relay(from src: Int32, to dst: Int32, onClose: @escaping () -> Void) {
        Thread.detachNewThread {
            let bufSize = 64 * 1024
            let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 1)
            defer { buf.deallocate(); onClose() }
            while true {
                let n = read(src, buf, bufSize)
                if n < 0 { if errno == EINTR { continue }; break }
                if n == 0 { break } // EOF
                var off = 0
                while off < n {
                    let w = write(dst, buf + off, n - off)
                    if w < 0 { if errno == EINTR { continue }; break }
                    off += w
                }
                if off < n { break }
            }
        }
    }

    private func errnoString() -> String { String(cString: strerror(errno)) }
}

/// Runs a closure at most once, thread-safely.
final class OnceFlag {
    private var done = false
    private let lock = NSLock()
    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

/// Hashable wrapper so we can hold strong references to live connections in a Set.
private final class VZVirtioSocketConnectionBox: Hashable {
    let connection: VZVirtioSocketConnection
    init(_ c: VZVirtioSocketConnection) { connection = c }
    static func == (l: VZVirtioSocketConnectionBox, r: VZVirtioSocketConnectionBox) -> Bool { l === r }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
