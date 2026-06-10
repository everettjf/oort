import Foundation

/// The guest→host relay direction, done safely.
///
/// VZ delivers EVERY vsock connection through one serial device queue that
/// does a BLOCKING writev into the connection's host-side fd (verified by
/// sampling com.apple.Virtualization.VirtualMachine during a live wedge). So
/// if our relay stops draining ONE connection — e.g. it's blocked writing to a
/// stuck client like `docker run … | head -1` — the socketpair fills, VZ's
/// device queue blocks, and the ENTIRE vsock device freezes: docker, the
/// agent, port forwards, everything, until the VM restarts.
///
/// Invariant therefore: NEVER stop reading a vsock fd while the connection is
/// open. This pump reads `src` unconditionally and buffers what the client
/// hasn't accepted yet (non-blocking writes), up to `maxBuffered`. A client
/// that lets that much pile up is stuck or gone — the connection is killed
/// (`onStall`) to protect the device; everyone else keeps flowing.
enum Relays {
    static let maxBuffered = 32 * 1024 * 1024

    /// One-direction copy for the host→guest path. Semantically a blocking
    /// splice, but EAGAIN-tolerant via poll: `drain` puts the CLIENT fd into
    /// non-blocking mode, and O_NONBLOCK is per-file-description — it affects
    /// this relay's reads of the same fd too.
    static func blockingCopy(from src: Int32, to dst: Int32,
                             onEOF: () -> Void, onBrokenPipe: () -> Void, onDone: () -> Void) {
        let bufSize = 64 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 1)
        defer { buf.deallocate(); onDone() }
        func wait(_ fd: Int32, _ events: Int32) {
            var p = [pollfd(fd: fd, events: Int16(events), revents: 0)]
            _ = poll(&p, 1, -1)
        }
        while true {
            let n = read(src, buf, bufSize)
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { wait(src, POLLIN); continue }
                break
            }
            if n == 0 { onEOF(); return } // clean EOF
            var off = 0
            var dead = false
            while off < n {
                let w = write(dst, buf + off, n - off)
                if w < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN { wait(dst, POLLOUT); continue }
                    dead = true; break
                }
                off += w
            }
            if dead { break } // write failed — peer gone
        }
        onBrokenPipe()
    }

    /// Pump src→dst. Clean src EOF (after the buffer flushes) runs `onEOF`;
    /// a dead/stuck dst runs `onStall`. `onDone` always runs last.
    static func drain(from src: Int32, to dst: Int32,
                      onEOF: @escaping () -> Void,
                      onStall: @escaping () -> Void, onDone: @escaping () -> Void) {
        Thread.detachNewThread {
            let flags = fcntl(dst, F_GETFL)
            _ = fcntl(dst, F_SETFL, flags | O_NONBLOCK)

            let chunkSize = 64 * 1024
            let chunk = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 1)
            defer { chunk.deallocate(); onDone() }

            var pending = Data()        // bytes read from src, not yet written to dst
            var srcEOF = false

            while true {
                var fds = [pollfd(fd: src, events: srcEOF ? 0 : Int16(POLLIN), revents: 0),
                           pollfd(fd: dst, events: pending.isEmpty ? 0 : Int16(POLLOUT), revents: 0)]
                let rc = poll(&fds, 2, -1)
                if rc < 0 { if errno == EINTR { continue }; onStall(); return }

                // Drain the guest side first — this is the invariant.
                if fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0, !srcEOF {
                    let n = read(src, chunk, chunkSize)
                    if n < 0 {
                        if errno != EINTR { onStall(); return }
                    } else if n == 0 {
                        srcEOF = true
                        if pending.isEmpty { onEOF(); return }
                    } else {
                        pending.append(Data(bytes: chunk, count: n))
                        if pending.count > maxBuffered { onStall(); return }
                    }
                }

                if fds[1].revents & Int16(POLLERR | POLLHUP) != 0, pending.isEmpty == false {
                    onStall(); return
                }
                if fds[1].revents & Int16(POLLOUT) != 0 {
                    let wrote: Int = pending.withUnsafeBytes { raw in
                        write(dst, raw.baseAddress, min(raw.count, 256 * 1024))
                    }
                    if wrote < 0 {
                        if errno == EAGAIN || errno == EINTR { continue }
                        onStall(); return
                    }
                    pending.removeFirst(wrote)
                    if pending.isEmpty && srcEOF { onEOF(); return }
                }
            }
        }
    }
}
