import Foundation
import Virtualization

/// `mac` from inside the guest (M14) — OrbStack's reverse direction: a Linux
/// shell runs a command ON THE MAC and gets its output and exit code back.
///
///   guest$ mac say "build done"
///   guest$ mac open https://example.com
///   guest$ mac pbpaste | grep token
///
/// The engine listens on a guest-reachable vsock port; the guest-side client
/// (`oort-guest mac …`, wrapped as /usr/local/bin/mac) sends one command line
/// and streams the combined output until a trailer line carries the exit code.
///
/// Trust model (same as OrbStack's `mac`): guest root can run commands as the
/// Mac user. The guest is already this user's trust domain — but it IS a
/// boundary crossing, so `--no-mac-exec` turns it off entirely.
final class MacExec: NSObject, VZVirtioSocketListenerDelegate {
    static let port: UInt32 = 2400
    /// Output is followed by one line: "\u{1}OORT-EXIT <code>".
    static let trailerPrefix = "\u{1}OORT-EXIT "

    private let listener = VZVirtioSocketListener()

    func attach(to device: VZVirtioSocketDevice) {
        listener.delegate = self
        device.setSocketListener(listener, forPort: MacExec.port)
        Log.info("mac-exec: guest 'mac' commands enabled (vsock:\(MacExec.port); --no-mac-exec to disable)")
    }

    func listener(_ listener: VZVirtioSocketListener,
                  shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        let fd = dup(connection.fileDescriptor)
        guard fd >= 0 else { return false }
        let hold = connection
        Thread.detachNewThread { [weak self] in
            self?.serve(fd)
            close(fd)
            _ = hold
        }
        return true
    }

    /// Read one command line, run it via the user's login shell, stream the
    /// combined output back, then the exit trailer.
    private func serve(_ fd: Int32) {
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var cmdData = Data()
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 1)
        defer { buf.deallocate() }
        while !cmdData.contains(0x0A) {
            let n = read(fd, buf, 4096)
            if n <= 0 { return }
            cmdData.append(Data(bytes: buf, count: n))
            if cmdData.count > 64 * 1024 { return } // a command line, not a payload
        }
        guard let nl = cmdData.firstIndex(of: 0x0A),
              let cmd = String(data: cmdData[..<nl], encoding: .utf8), !cmd.isEmpty else { return }

        let proc = Process()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-lc", cmd]
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch {
            write(fd, "mac: cannot run \(shell): \(error.localizedDescription)\n")
            write(fd, MacExec.trailerPrefix + "127\n")
            return
        }
        // Stream as it arrives (drain continuously — never buffer unbounded).
        let out = pipe.fileHandleForReading
        while true {
            let chunk = out.availableData
            if chunk.isEmpty { break }
            var off = 0
            chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                while off < raw.count {
                    let w = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                    if w <= 0 { proc.terminate(); off = raw.count; return }
                    off += w
                }
            }
        }
        proc.waitUntilExit()
        write(fd, MacExec.trailerPrefix + "\(proc.terminationStatus)\n")
    }

    private func write(_ fd: Int32, _ s: String) {
        _ = s.withCString { Darwin.write(fd, $0, strlen($0)) }
    }
}
