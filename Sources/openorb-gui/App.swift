import SwiftUI
import Foundation

// M8: a minimal native menu-bar app wrapping the openorb engine. It shows live
// status (VM running, Docker version, container count) read straight from the
// pidfile and the projected Docker socket, and start/stop via the `orb` script.
// A small, honest GUI — the surface OrbStack puts in its menu bar.

@main
struct OpenorbGUIApp: App {
    @StateObject private var model = StatusModel()

    var body: some Scene {
        MenuBarExtra("openorb", systemImage: model.running ? "shippingbox.fill" : "shippingbox") {
            Text(model.line1).font(.headline)
            Text(model.line2).foregroundStyle(.secondary)
            Divider()
            if model.running {
                Button("Stop openorb") { model.orb("stop") }
                Button("Copy DOCKER_HOST") { model.copyDockerHost() }
            } else {
                Button("Start openorb") { model.orb("start") }
            }
            Button("Refresh") { model.refresh() }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}

@MainActor
final class StatusModel: ObservableObject {
    @Published var running = false
    @Published var line1 = "openorb: …"
    @Published var line2 = ""

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var stateDir: URL { home.appendingPathComponent(".openorb") }
    private var dockerSock: String { stateDir.appendingPathComponent("docker.sock").path }
    private var pidFile: String { stateDir.appendingPathComponent("vm.pid").path }
    private var dockerHost: String { "unix://\(dockerSock)" }

    init() {
        refresh()
        Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let up = vmRunning()
        running = up
        guard up else { line1 = "openorb: stopped"; line2 = "Start it from the menu"; return }
        if let ver = dockerVersion() {
            line1 = "Docker \(ver) — running"
            line2 = "\(containerCount()) container(s) · DOCKER_HOST set via menu"
        } else {
            line1 = "openorb: starting…"
            line2 = "waiting for Docker"
        }
    }

    private func vmRunning() -> Bool {
        guard let s = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == 0
    }

    private func dockerVersion() -> String? {
        guard let body = dockerGet("/version"),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let v = json["Version"] as? String, let arch = json["Arch"] as? String else { return nil }
        return "\(v) \(json["Os"] as? String ?? "linux")/\(arch)"
    }

    private func containerCount() -> Int {
        guard let body = dockerGet("/containers/json"),
              let arr = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else { return 0 }
        return arr.count
    }

    func copyDockerHost() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("export DOCKER_HOST=\(dockerHost)", forType: .string)
    }

    /// Run an `orb` subcommand (start/stop) in the background.
    func orb(_ cmd: String) {
        guard let orbPath = locateOrb() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [orbPath, cmd]
        try? p.run()
    }

    private func locateOrb() -> String? {
        // OPENORB_HOME, else the repo next to the running executable, else CWD.
        if let h = ProcessInfo.processInfo.environment["OPENORB_HOME"] {
            let p = "\(h)/orb"; if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        // .build/<...>/release/openorb-gui → walk up to the package root
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<6 {
            let cand = dir.appendingPathComponent("orb").path
            if FileManager.default.isExecutableFile(atPath: cand) { return cand }
            dir = dir.deletingLastPathComponent()
        }
        let cwd = "\(FileManager.default.currentDirectoryPath)/orb"
        return FileManager.default.isExecutableFile(atPath: cwd) ? cwd : nil
    }

    /// Minimal HTTP/1.0 GET over the projected Docker Unix socket.
    private func dockerGet(_ path: String) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(dockerSock.utf8)
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
        while true { let r = read(fd, buf, n); if r <= 0 { break }; resp.append(Data(bytes: buf, count: r)) }
        guard let sep = resp.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return resp.subdata(in: sep.upperBound..<resp.endIndex)
    }
}
