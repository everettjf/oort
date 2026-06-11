import SwiftUI
import Foundation

// Service layer for the GUI: a tiny Docker Engine API client over the projected
// Unix socket, an `oort` script runner, the data models, and the observable
// AppModel that the views bind to. No external dependencies — same approach as
// the engine itself (raw sockets + Process).

// MARK: - Models

struct DContainer: Identifiable, Hashable {
    let id: String
    let name: String
    let image: String
    let state: String        // running / exited / created …
    let status: String       // "Up 3 minutes" …
    let ports: String        // "0.0.0.0:8080->80/tcp" …
    var isMachine: Bool { name.hasPrefix("ovm-") }
}

struct DImage: Identifiable, Hashable {
    let id: String
    let repoTags: String
    let size: String
    let created: String
}

struct DVolume: Identifiable, Hashable {
    let id: String           // name
    let driver: String
    let mountpoint: String
}

struct Machine: Identifiable, Hashable {
    let id: String           // short name (no ovm- prefix)
    let distro: String
    let status: String
    let running: Bool
}

// MARK: - Docker API client (HTTP/1.0 over the projected Unix socket)

struct DockerClient {
    let socketPath: String

    /// One request/response over the Unix socket. Returns (statusCode, body).
    @discardableResult
    func request(_ method: String, _ path: String, body: Data? = nil, timeout: Int = 8) -> (Int, Data)? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { return nil }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var req = "\(method) \(path) HTTP/1.0\r\nHost: localhost\r\n"
        if let body {
            req += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        }
        req += "Connection: close\r\n\r\n"
        var out = Data(req.utf8)
        if let body { out.append(body) }
        out.withUnsafeBytes { _ = write(fd, $0.baseAddress, out.count) }

        var resp = Data()
        let n = 64 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 1)
        defer { buf.deallocate() }
        while true { let r = read(fd, buf, n); if r <= 0 { break }; resp.append(Data(bytes: buf, count: r)) }
        guard let sep = resp.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let header = String(data: resp.subdata(in: resp.startIndex..<sep.lowerBound), encoding: .utf8) ?? ""
        let code = header.split(separator: "\r\n").first.flatMap { line -> Int? in
            let parts = line.split(separator: " "); return parts.count > 1 ? Int(parts[1]) : nil
        } ?? 0
        return (code, resp.subdata(in: sep.upperBound..<resp.endIndex))
    }

    func getJSON(_ path: String) -> Any? {
        guard let (code, data) = request("GET", path), code == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

// MARK: - AppModel

@MainActor
final class AppModel: ObservableObject {
    @Published var running = false
    @Published var starting = false
    @Published var dockerVersion = ""
    @Published var dockerInfo = ""        // "N containers · M images"
    @Published var containers: [DContainer] = []
    @Published var images: [DImage] = []
    @Published var volumes: [DVolume] = []
    @Published var machines: [Machine] = []
    @Published var autostart = false
    @Published var lastError = ""

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var stateDir: URL { home.appendingPathComponent(".oort") }
    var dockerSock: String { stateDir.appendingPathComponent("docker.sock").path }
    var dockerHost: String { "unix://\(dockerSock)" }
    private var pidFile: String { stateDir.appendingPathComponent("vm.pid").path }
    private var client: DockerClient { DockerClient(socketPath: dockerSock) }

    init() {
        refresh()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: status + lists

    func refresh() {
        running = vmRunning()
        autostart = FileManager.default.fileExists(
            atPath: home.appendingPathComponent("Library/LaunchAgents/dev.oort.plist").path)
        guard running else {
            dockerVersion = ""; dockerInfo = ""
            containers = []; images = []; volumes = []; machines = []
            return
        }
        if let v = client.getJSON("/version") as? [String: Any], let ver = v["Version"] as? String {
            starting = false
            dockerVersion = "\(ver) · \(v["Os"] as? String ?? "linux")/\(v["Arch"] as? String ?? "")"
            loadContainers(); loadImages(); loadVolumes()
            dockerInfo = "\(containers.filter { $0.state == "running" }.count)/\(containers.count) containers · \(images.count) images · \(volumes.count) volumes"
        } else {
            starting = true
            dockerVersion = ""; dockerInfo = "waiting for Docker…"
        }
    }

    private func loadContainers() {
        guard let arr = client.getJSON("/containers/json?all=1") as? [[String: Any]] else { return }
        let all = arr.map { c -> DContainer in
            let names = (c["Names"] as? [String])?.first ?? "/?"
            let ports = (c["Ports"] as? [[String: Any]])?.compactMap { p -> String? in
                guard let priv = p["PrivatePort"] as? Int else { return nil }
                if let pub = p["PublicPort"] as? Int { return "\(pub)→\(priv)" }
                return "\(priv)"
            }.joined(separator: " ") ?? ""
            return DContainer(
                id: (c["Id"] as? String ?? "").prefix(12).description,
                name: String(names.dropFirst()),
                image: c["Image"] as? String ?? "",
                state: c["State"] as? String ?? "",
                status: c["Status"] as? String ?? "",
                ports: ports)
        }
        containers = all.filter { !$0.isMachine }.sorted { $0.name < $1.name }
        // machines are containers named ovm-*; surface them in their own panel.
        machines = all.filter { $0.isMachine }.map {
            Machine(id: String($0.name.dropFirst(4)), distro: $0.image, status: $0.status, running: $0.state == "running")
        }.sorted { $0.id < $1.id }
    }

    private func loadImages() {
        guard let arr = client.getJSON("/images/json") as? [[String: Any]] else { return }
        images = arr.map { i in
            let tags = (i["RepoTags"] as? [String])?.filter { $0 != "<none>:<none>" }
            let size = (i["Size"] as? Int).map { byteCount($0) } ?? ""
            return DImage(
                id: (i["Id"] as? String ?? "").replacingOccurrences(of: "sha256:", with: "").prefix(12).description,
                repoTags: (tags?.isEmpty == false ? tags!.joined(separator: ", ") : "<none>"),
                size: size,
                created: relative(i["Created"] as? Int))
        }.sorted { $0.repoTags < $1.repoTags }
    }

    private func loadVolumes() {
        guard let obj = client.getJSON("/volumes") as? [String: Any],
              let arr = obj["Volumes"] as? [[String: Any]] else { volumes = []; return }
        volumes = arr.map { v in
            DVolume(id: v["Name"] as? String ?? "?", driver: v["Driver"] as? String ?? "",
                    mountpoint: v["Mountpoint"] as? String ?? "")
        }.sorted { $0.id < $1.id }
    }

    // MARK: container actions

    func container(_ id: String, action: String) {       // start/stop/restart
        Task.detached { _ = DockerClient(socketPath: await self.dockerSock).request("POST", "/containers/\(id)/\(action)", timeout: 30)
            await MainActor.run { self.refresh() } }
    }
    func removeContainer(_ id: String) {
        Task.detached { _ = DockerClient(socketPath: await self.dockerSock).request("DELETE", "/containers/\(id)?force=1", timeout: 30)
            await MainActor.run { self.refresh() } }
    }
    func removeImage(_ id: String) {
        Task.detached { _ = DockerClient(socketPath: await self.dockerSock).request("DELETE", "/images/\(id)?force=1", timeout: 30)
            await MainActor.run { self.refresh() } }
    }
    func removeVolume(_ name: String) {
        Task.detached { _ = DockerClient(socketPath: await self.dockerSock).request("DELETE", "/volumes/\(name)", timeout: 30)
            await MainActor.run { self.refresh() } }
    }

    /// Container logs via the `oort docker logs` CLI (the API stream is multiplexed
    /// with frame headers; the CLI de-muxes it for us).
    func logs(_ id: String) -> String { runOorb(["docker", "logs", "--tail", "300", id]) }

    // MARK: VM lifecycle

    func startVM() { starting = true; runOorbAsync(["start"]) }
    func stopVM()  { runOorbAsync(["stop"]) }
    func restartVM() { starting = true; runOorbAsync(["restart"]) }
    func setAutostart(_ on: Bool) { runOorbAsync(["autostart", on ? "enable" : "disable"]) }

    func copyDockerHost() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("export DOCKER_HOST=\(dockerHost)", forType: .string)
    }

    // MARK: machine actions

    func machineCreate(_ name: String, distro: String) { runOorbAsync(["machine", "create", name, distro]) }
    func machineDelete(_ name: String) { runOorbAsync(["machine", "delete", name, "--purge"]) }
    func machineSnapshot(_ name: String) { runOorbAsync(["machine", "snapshot", name]) }
    func machineRestore(_ name: String) { runOorbAsync(["machine", "restore", name]) }
    func machineFork(_ src: String, _ dst: String) { runOorbAsync(["machine", "fork", src, dst]) }
    /// Open Terminal.app on an interactive shell into the machine.
    func machineShell(_ name: String) {
        guard let orb = locateOrb() else { return }
        let cmd = "clear; '\(orb)' machine shell \(name)"
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(cmd)\"\nend tell"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]; try? p.run()
    }

    // MARK: helpers

    private func vmRunning() -> Bool {
        guard let s = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == 0
    }

    /// Run an `oort` subcommand, capturing stdout+stderr (synchronous).
    @discardableResult
    func runOorb(_ args: [String]) -> String {
        guard let orb = locateOrb() else { return "oort not found" }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [orb] + args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return "failed: \(error)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Fire-and-forget `oort` (start/stop/machine ops); refresh when it finishes.
    func runOorbAsync(_ args: [String]) {
        guard let orb = locateOrb() else { lastError = "oort not found"; return }
        Task.detached {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [orb] + args
            try? p.run(); p.waitUntilExit()
            await MainActor.run { self.refresh() }
        }
    }

    func locateOrb() -> String? {
        if let h = ProcessInfo.processInfo.environment["OORT_HOME"] {
            let p = "\(h)/oort"; if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        // Self-contained app (M15): the complete oort home ships in Resources.
        if let res = Bundle.main.resourcePath {
            let p = "\(res)/oort-home/oort"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let cand = dir.appendingPathComponent("oort").path
            if FileManager.default.isExecutableFile(atPath: cand) { return cand }
            dir = dir.deletingLastPathComponent()
        }
        let cwd = "\(FileManager.default.currentDirectoryPath)/oort"
        return FileManager.default.isExecutableFile(atPath: cwd) ? cwd : nil
    }

    private func byteCount(_ n: Int) -> String {
        let f = ByteCountFormatter(); f.countStyle = .binary; return f.string(fromByteCount: Int64(n))
    }
    private func relative(_ epoch: Int?) -> String {
        guard let epoch else { return "" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(epoch)), relativeTo: Date())
    }
}
