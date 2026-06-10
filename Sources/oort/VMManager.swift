import Foundation
import Virtualization

/// Owns the VM lifecycle. All VZ object access happens on `vmQueue` — that's a
/// hard requirement of Virtualization.framework, which is why the VM is created
/// with `init(configuration:queue:)` and every call is dispatched onto it.
final class VMManager: NSObject, VZVirtualMachineDelegate {
    private let cfg: Config
    private let vmQueue = DispatchQueue(label: "dev.oort.vm")
    private var vm: VZVirtualMachine!
    private var proxies: [DockerSocketProxy] = []
    private var portForwarder: PortForwarder?
    private var memoryManager: MemoryManager?
    private var dnsResponder: DNSResponder?
    private var macExec: MacExec?
    private var configuredMemory: UInt64 = 0
    private var diskLock: DiskLock?

    init(_ cfg: Config) { self.cfg = cfg }

    func startAndProject() throws {
        // Take an exclusive lock on the disk before touching it, so two VMs can
        // never write the same image at once (that corrupts the guest fs). Held
        // for the process lifetime; the kernel drops it automatically on exit.
        diskLock = try DiskLock(diskImage: cfg.diskImage)

        let configuration = try VMConfig.make(cfg)
        configuredMemory = configuration.memorySize
        Log.info("config: cpus=\(configuration.cpuCount) memory=\(configuration.memorySize / (1024*1024))MiB")

        // Surface exactly which device blocks suspend/resume (M8) — VZ's restore
        // errors are opaque ("invalid argument"), but this validation names it.
        if #available(macOS 14, *), cfg.restoreState != nil {
            do { try configuration.validateSaveRestoreSupport() }
            catch { Log.warn("suspend/resume unsupported by this config: \(error.localizedDescription)") }
        }

        vmQueue.sync {
            self.vm = VZVirtualMachine(configuration: configuration, queue: self.vmQueue)
            self.vm.delegate = self
        }

        // Instant start (M8): if a suspended-state file exists, restore the whole
        // VM (RAM + devices) instead of cold-booting — sub-second, and running
        // containers come back exactly where they were. The state is one-shot:
        // delete it the moment the restore succeeds, because resumed RAM diverges
        // from it immediately (restoring it twice would corrupt the guest fs).
        if #available(macOS 14, *),
           let stateURL = cfg.restoreState, FileManager.default.fileExists(atPath: stateURL.path) {
            vmQueue.async {
                self.vm.restoreMachineStateFrom(url: stateURL) { err in
                    if let err {
                        // Unsupported device / config drift / stale file — cold-boot.
                        // "permission denied" specifically = the state file's
                        // decryption key is unavailable while the SCREEN IS
                        // LOCKED (macOS data protection); the state itself is
                        // fine, but by the time the user unlocks we're already
                        // cold-booting, so it can't be kept for later.
                        var detail = err.localizedDescription
                        if detail.contains("permission denied") {
                            detail += " — usually the screen is locked; resume needs an unlocked session"
                        }
                        Log.warn("restore failed (\(detail)); cold-booting")
                        try? FileManager.default.removeItem(at: stateURL)
                        self.coldStart()
                        return
                    }
                    try? FileManager.default.removeItem(at: stateURL)
                    self.vm.resume { result in
                        switch result {
                        case .failure(let err):
                            Log.error("VM failed to resume: \(err.localizedDescription)")
                            exit(1)
                        case .success:
                            Log.info("VM resumed from suspended state")
                            self.startProxy()
                        }
                    }
                }
            }
            return
        }
        vmQueue.async { self.coldStart() }
    }

    /// Plain cold boot. Must run on `vmQueue`.
    private func coldStart() {
        vm.start { result in
            switch result {
            case .failure(let err):
                Log.error("VM failed to start: \(err.localizedDescription)")
                exit(1)
            case .success:
                Log.info("VM started")
                self.startProxy()
            }
        }
    }

    /// Suspend (M8): pause the VM and save its whole state (RAM + devices) to
    /// disk, then exit. The next `oort start` restores it in well under a second
    /// — with every container still running. On any failure the VM is resumed
    /// and keeps running, so a suspend can never lose a working VM.
    func requestSuspend(to stateURL: URL) {
        guard #available(macOS 14, *) else {
            Log.warn("suspend needs macOS 14+ — ignoring")
            return
        }
        vmQueue.async {
            guard let vm = self.vm, vm.canPause else {
                Log.warn("suspend: VM not pausable right now — ignoring")
                return
            }
            vm.pause { result in
                if case .failure(let err) = result {
                    Log.warn("suspend: pause failed (\(err.localizedDescription)) — VM keeps running")
                    return
                }
                try? FileManager.default.removeItem(at: stateURL)
                vm.saveMachineStateTo(url: stateURL) { err in
                    if let err {
                        Log.warn("suspend: save failed (\(err.localizedDescription)) — resuming")
                        try? FileManager.default.removeItem(at: stateURL)
                        vm.resume { _ in }
                        return
                    }
                    Log.info("VM state saved to \(stateURL.path) — exiting (next start resumes instantly)")
                    exit(0)
                }
            }
        }
    }

    /// vsock port where the agent drops all previously-bridged connections.
    /// Critical after a suspend/resume: the restored guest still holds vsock
    /// sockets whose host peers died with the old engine process and will
    /// never RST — each one strands agent goroutines+fds until execs starve.
    private static let guestResetPort: UInt32 = 2379

    private func startProxy() {
        // Must read socketDevices on the VM queue (we're already on it here).
        guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
            Log.error("no virtio-socket device on the VM")
            return
        }

        device.connect(toPort: VMManager.guestResetPort) { result in
            if case .success(let conn) = result {
                Log.info("asked the agent to drop stale bridged connections")
                close(dup(conn.fileDescriptor)) // connecting IS the request
            }
            // Failure is fine: cold boot (agent not up yet — nothing stale).
        }
        // The Docker socket plus any extra --forward targets are all just
        // host-Unix-socket ⇄ guest-vsock-port tunnels.
        var targets: [Config.Forward] = [.init(socketPath: cfg.hostSocketPath, guestPort: cfg.guestVsockPort)]
        targets.append(contentsOf: cfg.forwards)

        for t in targets {
            let proxy = DockerSocketProxy(
                socketPath: t.socketPath,
                guestPort: t.guestPort,
                vmQueue: vmQueue,
                socketDevice: device
            )
            do {
                try proxy.start()
                proxies.append(proxy)
            } catch {
                Log.error("failed to start forward \(t.socketPath) → vsock:\(t.guestPort): \(error)")
            }
        }

        if cfg.portForward || !cfg.tcpForwards.isEmpty {
            let pf = PortForwarder(dockerSocketPath: cfg.hostSocketPath, vmQueue: vmQueue,
                                   socketDevice: device, staticPorts: cfg.tcpForwards)
            pf.start()
            portForwarder = pf
        }

        if cfg.dnsPort > 0 {
            let dns = DNSResponder(dockerSocketPath: cfg.hostSocketPath, port: cfg.dnsPort)
            dns.start()
            dnsResponder = dns
        }

        if cfg.macExec {
            let me = MacExec()
            me.attach(to: device)
            macExec = me
        }

        if cfg.dynamicMemory,
           let balloon = vm.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice {
            let mm = MemoryManager(device: balloon, vmQueue: vmQueue, socketDevice: device,
                                   configuredBytes: configuredMemory)
            mm.start()
            memoryManager = mm
        }
        printReadyBanner()
    }

    private func printReadyBanner() {
        let banner = """

        ─────────────────────────────────────────────────────────────
         oort stage-1 ready
           export DOCKER_HOST=unix://\(cfg.hostSocketPath)
           docker ps
         (Ctrl-C to stop the VM)
        ─────────────────────────────────────────────────────────────
        """
        FileHandle.standardError.write(Data(banner.utf8))
    }

    /// vsock port where the guest agent listens for a clean-poweroff request.
    /// Must match `shutdownPort` in guest-agent/main.go.
    private static let guestShutdownPort: UInt32 = 2378

    func requestStop() {
        vmQueue.async {
            guard let vm = self.vm else { exit(0) }
            // Preferred path: ask the guest agent to sync the filesystem and power
            // off cleanly (graceful systemd, sysrq fallback). This guarantees the
            // disk image is flushed and consistent, so we never need a force-kill —
            // the force-kill is what corrupted the disk and broke the next boot.
            if let device = vm.socketDevices.first as? VZVirtioSocketDevice {
                device.connect(toPort: VMManager.guestShutdownPort) { result in
                    switch result {
                    case .success:
                        // The agent powers off on connect; guestDidStop will fire.
                        Log.info("requested clean guest poweroff via agent")
                    case .failure(let err):
                        // Agent unreachable (e.g. it never came up on a damaged
                        // disk) — fall back to an ACPI stop request.
                        Log.warn("agent shutdown port unreachable (\(err.localizedDescription)); falling back to ACPI")
                        self.acpiStop()
                    }
                }
            } else {
                self.acpiStop()
            }
        }
    }

    /// ACPI graceful-stop request. Must run on `vmQueue`.
    private func acpiStop() {
        guard let vm = self.vm, vm.canRequestStop else { exit(0) }
        do { try vm.requestStop() } catch { exit(0) }
    }

    // MARK: - VZVirtualMachineDelegate

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Log.info("guest stopped"); exit(0)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Log.error("VM stopped with error: \(error.localizedDescription)"); exit(1)
    }
}
