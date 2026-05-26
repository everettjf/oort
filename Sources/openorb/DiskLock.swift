import Foundation

/// An advisory, process-wide exclusive lock on the VM's disk image.
///
/// Two VMs writing the same raw disk at once corrupt the guest ext4 filesystem
/// and break the next boot's networking — the single most painful durability
/// bug found during Phase 0 hardening (force-kills + concurrent starts). The
/// `orb` wrapper has a best-effort `pgrep` guard, but that's racy (TOCTOU) and
/// pattern-based; this is the real safety net, enforced in the one place every
/// boot must pass through.
///
/// We lock a sidecar `<disk>.lock` file rather than the image itself, so the
/// lock is independent of how VZ opens the disk. The kernel releases `flock`
/// locks automatically when the fd closes or the process dies, so a crash never
/// leaves a stale lock behind — no manual cleanup, unlike a pidfile.
final class DiskLock {
    private var fd: Int32 = -1

    /// Acquire the lock, or throw if another openorb VM already holds it.
    init(diskImage: URL) throws {
        let lockPath = diskImage.path + ".lock"
        fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw CLIError.runtime("cannot open disk lock \(lockPath): \(String(cString: strerror(errno)))")
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let e = errno
            close(fd); fd = -1
            if e == EWOULDBLOCK {
                throw CLIError.runtime(
                    "disk '\(diskImage.lastPathComponent)' is already in use by another openorb VM — "
                    + "run 'orb stop' first (concurrent writers would corrupt it)")
            }
            throw CLIError.runtime("cannot lock disk \(diskImage.path): \(String(cString: strerror(e)))")
        }
    }

    deinit { if fd >= 0 { close(fd) } }
}
