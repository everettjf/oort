import Foundation
import Virtualization

/// Stage 3: make container-published ports reachable on the macOS localhost,
/// the way OrbStack does.
///
/// It polls the Docker API (over the projected socket) for containers with
/// published TCP ports. For each port P it opens a `127.0.0.1:P` listener on
/// macOS; each accepted connection is tunnelled over vsock to the guest agent's
/// forward port (2377), which dials `127.0.0.1:P` inside the guest and splices.
final class PortForwarder {
    private let dockerSocketPath: String
    private let vmQueue: DispatchQueue
    private weak var socketDevice: VZVirtioSocketDevice?
    private let guestForwardPort: UInt32

    private let lock = NSLock()
    private var listeners: [Int: Int32] = [:]   // hostPort -> listening fd

    init(dockerSocketPath: String, vmQueue: DispatchQueue, socketDevice: VZVirtioSocketDevice, guestForwardPort: UInt32 = 2377) {
        self.dockerSocketPath = dockerSocketPath
        self.vmQueue = vmQueue
        self.socketDevice = socketDevice
        self.guestForwardPort = guestForwardPort
    }

    func start() {
        Log.info("port forwarding: watching Docker for published ports → 127.0.0.1")
        Thread.detachNewThread { [weak self] in self?.pollLoop() }
    }

    private func pollLoop() {
        while true {
            reconcile(desired: publishedPorts())
            Thread.sleep(forTimeInterval: 2)
        }
    }

    // MARK: - Reconcile listeners against the desired port set

    private func reconcile(desired: Set<Int>) {
        lock.lock(); defer { lock.unlock() }
        for port in desired where listeners[port] == nil {
            if let fd = openListener(port) {
                listeners[port] = fd
                Log.info("forwarding 127.0.0.1:\(port) → guest:\(port)")
            }
        }
        for (port, fd) in listeners where !desired.contains(port) {
            close(fd)
            listeners.removeValue(forKey: port)
            Log.info("stopped forwarding 127.0.0.1:\(port)")
        }
    }

    private func openListener(_ port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 128) == 0 else { close(fd); return nil }
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd, port: port) }
        return fd
    }

    private func acceptLoop(_ listenFD: Int32, port: Int) {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return // listener closed
            }
            tunnel(clientFD: client, port: port)
        }
    }

    // MARK: - Per-connection vsock tunnel (prefixed with the target port)

    private func tunnel(clientFD: Int32, port: Int) {
        vmQueue.async { [weak self] in
            guard let self, let device = self.socketDevice else { close(clientFD); return }
            device.connect(toPort: self.guestForwardPort) { result in
                switch result {
                case .failure:
                    close(clientFD)
                case .success(let connection):
                    let guestFD = dup(connection.fileDescriptor)
                    guard guestFD >= 0 else { close(clientFD); return }
                    // Tell the guest agent which port to dial, then splice.
                    let hdr = "\(port)\n"
                    _ = hdr.withCString { write(guestFD, $0, strlen($0)) }
                    self.splice(clientFD, guestFD, hold: connection)
                }
            }
        }
    }

    private func splice(_ a: Int32, _ b: Int32, hold: VZVirtioSocketConnection) {
        let once = OnceFlag()
        let teardown = { once.run { shutdown(a, SHUT_RDWR); shutdown(b, SHUT_RDWR) } }
        let group = DispatchGroup()
        group.enter(); group.enter()
        copy(a, b) { teardown(); group.leave() }
        copy(b, a) { teardown(); group.leave() }
        group.notify(queue: .global()) { close(a); close(b); _ = hold }
    }

    private func copy(_ src: Int32, _ dst: Int32, done: @escaping () -> Void) {
        Thread.detachNewThread {
            let n = 64 * 1024
            let buf = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 1)
            defer { buf.deallocate(); done() }
            while true {
                let r = read(src, buf, n)
                if r < 0 { if errno == EINTR { continue }; break }
                if r == 0 { break }
                var off = 0
                while off < r {
                    let w = write(dst, buf + off, r - off)
                    if w < 0 { if errno == EINTR { continue }; break }
                    off += w
                }
                if off < r { break }
            }
        }
    }

    // MARK: - Docker API: list published TCP ports

    private func publishedPorts() -> Set<Int> {
        guard let body = httpGet("/containers/json"),
              let json = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else {
            return []
        }
        var ports = Set<Int>()
        for container in json {
            guard let list = container["Ports"] as? [[String: Any]] else { continue }
            for p in list {
                if (p["Type"] as? String) == "tcp", let pub = p["PublicPort"] as? Int, pub > 0 {
                    ports.insert(pub)
                }
            }
        }
        return ports
    }

    /// Minimal HTTP/1.0 GET over the projected Docker Unix socket.
    private func httpGet(_ path: String) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(dockerSocketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { return nil }
        // dockerd may keep the connection open even for HTTP/1.0, so a plain
        // read-until-EOF would block forever. Cap reads with a recv timeout.
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let req = "GET \(path) HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        _ = req.withCString { write(fd, $0, strlen($0)) }
        var resp = Data()
        let n = 64 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 1)
        defer { buf.deallocate() }
        while true {
            let r = read(fd, buf, n)
            if r <= 0 { break }
            resp.append(Data(bytes: buf, count: r))
        }
        guard let sep = resp.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return resp.subdata(in: sep.upperBound..<resp.endIndex)
    }
}
