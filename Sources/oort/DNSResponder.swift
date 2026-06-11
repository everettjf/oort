import Foundation

/// `*.oort.local` domains (M7) — reach containers and machines by name,
/// the way OrbStack's `*.orb.local` works.
///
/// A tiny DNS server on `127.0.0.1:<port>` (UDP). macOS routes every
/// `*.oort.local` query here via a domain-scoped resolver file
/// (`/etc/resolver/oort.local`, written by `oort domains enable`). Answers come
/// straight from the Docker API over the projected socket:
///
///   web.oort.local            → the container named "web"
///   dev.oort.local            → the machine "dev" (container "ovm-dev")
///   api.myproj.oort.local     → compose service "api" of project "myproj"
///
/// Names resolve to the container's bridge IP (172.17.0.x), which the Mac
/// reaches via the `oort domains`/`oort route` guest route — so *any* container
/// port works, no `-p` publishing needed. Unknown names get NXDOMAIN.
final class DNSResponder {
    private let dockerSocketPath: String
    private let port: UInt16
    private static let suffix = ".oort.local"
    /// Machine containers are named "<prefix><machine>" (see the CLI's
    /// MACHINE_PREFIX) — let "dev.oort.local" find machine "dev" directly.
    private static let machinePrefix = "ovm-"

    // Container lookups are cached briefly so a burst of queries (a browser
    // resolves A + AAAA + HTTPS at once) costs one Docker API call.
    private let lock = NSLock()
    private var table: [String: String] = [:]   // lowercased name → IPv4
    private var tableAt: Date = .distantPast
    private let tableTTL: TimeInterval = 2

    /// Host Unix socket bridged to the guest agent's exec port — used to ask
    /// k3s about Services for `*.k8s.oort.local` (M16). Optional: without it,
    /// k8s names just NXDOMAIN.
    private let agentSocketPath: String?
    private var k8sTable: [String: String] = [:]   // "svc.ns" → ClusterIP
    private var k8sTableAt: Date = .distantPast
    private let k8sTableTTL: TimeInterval = 5

    init(dockerSocketPath: String, port: UInt16 = 5354, agentSocketPath: String? = nil) {
        self.dockerSocketPath = dockerSocketPath
        self.port = port
        self.agentSocketPath = agentSocketPath
    }

    func start() {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { Log.error("dns: socket() failed"); return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port.bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Log.warn("dns: cannot bind 127.0.0.1:\(port) (\(String(cString: strerror(errno)))) — *.oort.local domains off")
            close(fd)
            return
        }
        Log.info("dns: *.oort.local resolver on 127.0.0.1:\(port) ('oort domains enable' to use it)")
        Thread.detachNewThread { [weak self] in self?.serveLoop(fd) }
    }

    private func serveLoop(_ fd: Int32) {
        let n = 1500
        let buf = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 1)
        defer { buf.deallocate(); close(fd) }
        while true {
            var peer = sockaddr_in()
            var peerLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let r = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, buf, n, 0, $0, &peerLen)
                }
            }
            if r < 0 { if errno == EINTR { continue }; return }
            guard r > 0 else { continue }
            let query = Data(bytes: buf, count: r)
            guard let reply = handle(query) else { continue }
            _ = reply.withUnsafeBytes { raw in
                withUnsafePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, raw.baseAddress, raw.count, 0, $0, peerLen)
                    }
                }
            }
        }
    }

    // MARK: - DNS wire format (just enough: one question in, one A answer out)

    private func handle(_ query: Data) -> Data? {
        // Header: ID(2) flags(2) QD(2) AN(2) NS(2) AR(2); need exactly 1 question.
        guard query.count > 12 else { return nil }
        let qdcount = Int(query[4]) << 8 | Int(query[5])
        guard qdcount >= 1 else { return nil }

        // QNAME: length-prefixed labels, NUL-terminated; then QTYPE + QCLASS.
        var labels: [String] = []
        var i = 12
        while i < query.count, query[i] != 0 {
            let len = Int(query[i])
            guard len <= 63, i + 1 + len <= query.count else { return nil }
            labels.append(String(decoding: query[(i+1)..<(i+1+len)], as: UTF8.self))
            i += 1 + len
        }
        guard i + 5 <= query.count else { return nil }
        let qtype = UInt16(query[i+1]) << 8 | UInt16(query[i+2])
        let questionEnd = i + 5
        let name = labels.joined(separator: ".").lowercased()

        var ip: String?
        var rcode: UInt8 = 3 // NXDOMAIN
        if name.hasSuffix(".k8s" + Self.suffix) {
            // <svc>.k8s.oort.local (default ns) or <svc>.<ns>.k8s.oort.local
            let host = String(name.dropLast((".k8s" + Self.suffix).count))
            if let found = resolveK8s(host) {
                ip = qtype == 1 ? found : nil
                rcode = 0
            }
        } else if name.hasSuffix(Self.suffix) {
            let host = String(name.dropLast(Self.suffix.count))
            if let found = resolve(host) {
                ip = qtype == 1 ? found : nil   // answer only A; AAAA/HTTPS → empty
                rcode = 0
            }
        }

        // Response: echo ID + question; QR=1 AA=1, copy RD; one A answer if found.
        var resp = Data()
        resp.append(query[0]); resp.append(query[1])                    // ID
        resp.append(0x84 | (query[2] & 0x01))                           // QR AA +RD
        resp.append(rcode)                                              // RA=0, RCODE
        resp.append(contentsOf: [0, 1])                                 // QDCOUNT
        resp.append(contentsOf: [0, ip != nil ? 1 : 0])                 // ANCOUNT
        resp.append(contentsOf: [0, 0, 0, 0])                           // NS, AR
        resp.append(query[12..<questionEnd])                            // question
        if let ip {
            let octets = ip.split(separator: ".").compactMap { UInt8($0) }
            guard octets.count == 4 else { return nil }
            resp.append(contentsOf: [0xC0, 0x0C])                       // name ptr → offset 12
            resp.append(contentsOf: [0, 1, 0, 1])                       // TYPE A, CLASS IN
            resp.append(contentsOf: [0, 0, 0, 5])                       // TTL 5s
            resp.append(contentsOf: [0, 4])                             // RDLENGTH
            resp.append(contentsOf: octets)
        }
        return resp
    }

    // MARK: - Name → container IP, from the Docker API

    private func resolve(_ host: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(tableAt) > tableTTL {
            table = buildTable()
            tableAt = Date()
        }
        return table[host]
    }

    /// One entry per running container under each name it answers to:
    /// the container name, the machine name (prefix stripped), and
    /// `<service>.<project>` for compose containers.
    private func buildTable() -> [String: String] {
        guard let body = httpGet("/containers/json"),
              let json = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else {
            return [:]
        }
        var t: [String: String] = [:]
        for c in json {
            guard let nets = (c["NetworkSettings"] as? [String: Any])?["Networks"] as? [String: Any],
                  let ip = nets.values
                      .compactMap({ ($0 as? [String: Any])?["IPAddress"] as? String })
                      .first(where: { !$0.isEmpty })
            else { continue }
            for raw in (c["Names"] as? [String]) ?? [] {
                let name = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
                t[name.lowercased()] = ip
                if name.hasPrefix(Self.machinePrefix) {
                    t[String(name.dropFirst(Self.machinePrefix.count)).lowercased()] = ip
                }
            }
            if let labels = c["Labels"] as? [String: String],
               let svc = labels["com.docker.compose.service"],
               let proj = labels["com.docker.compose.project"] {
                t["\(svc).\(proj)".lowercased()] = ip
            }
        }
        return t
    }

    // MARK: - k8s Services (M16): "svc" / "svc.ns" → ClusterIP, via the agent

    private func resolveK8s(_ host: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(k8sTableAt) > k8sTableTTL {
            k8sTable = buildK8sTable()
            k8sTableAt = Date()
        }
        return k8sTable[host] ?? k8sTable[host + ".default"]
    }

    /// Ask k3s (inside the guest, via the agent's exec socket) for all
    /// Services. One line per service: "name ns clusterIP".
    private func buildK8sTable() -> [String: String] {
        guard let agentSocketPath else { return [:] }
        let cmd = #"k3s kubectl get svc -A --no-headers -o custom-columns=N:.metadata.name,NS:.metadata.namespace,IP:.spec.clusterIP 2>/dev/null"#
        guard let out = execViaAgent(agentSocketPath, cmd) else { return [:] }
        var t: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }
            let name = parts[0].lowercased(), ns = parts[1].lowercased(), ip = String(parts[2])
            guard ip.contains("."), ip != "<none>" else { continue }
            t["\(name).\(ns)"] = ip
            if ns == "default" { t[name] = ip }
        }
        return t
    }

    /// POST a command to the agent's exec endpoint via its host Unix socket.
    private func execViaAgent(_ path: String, _ cmd: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { return nil }
        var tv = timeval(tv_sec: 4, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let req = "POST / HTTP/1.0\r\nContent-Length: \(cmd.utf8.count)\r\nConnection: close\r\n\r\n\(cmd)"
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
        return String(data: resp.subdata(in: sep.upperBound..<resp.endIndex), encoding: .utf8)
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
        var tv = timeval(tv_sec: 2, tv_usec: 0)
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
