import Foundation
import Virtualization

/// Owns the VM lifecycle. All VZ object access happens on `vmQueue` — that's a
/// hard requirement of Virtualization.framework, which is why the VM is created
/// with `init(configuration:queue:)` and every call is dispatched onto it.
final class VMManager: NSObject, VZVirtualMachineDelegate {
    private let cfg: Config
    private let vmQueue = DispatchQueue(label: "dev.openorb.vm")
    private var vm: VZVirtualMachine!
    private var proxies: [DockerSocketProxy] = []
    private var portForwarder: PortForwarder?
    private var memoryManager: MemoryManager?
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

        vmQueue.sync {
            self.vm = VZVirtualMachine(configuration: configuration, queue: self.vmQueue)
            self.vm.delegate = self
        }

        vmQueue.async {
            self.vm.start { result in
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
    }

    private func startProxy() {
        // Must read socketDevices on the VM queue (we're already on it here).
        guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
            Log.error("no virtio-socket device on the VM")
            return
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
         openorb stage-1 ready
           export DOCKER_HOST=unix://\(cfg.hostSocketPath)
           docker ps
         (Ctrl-C to stop the VM)
        ─────────────────────────────────────────────────────────────
        """
        FileHandle.standardError.write(Data(banner.utf8))
    }

    func requestStop() {
        vmQueue.async {
            guard let vm = self.vm, vm.canRequestStop else { exit(0) }
            do { try vm.requestStop() } catch { exit(0) }
        }
    }

    // MARK: - VZVirtualMachineDelegate

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Log.info("guest stopped"); exit(0)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Log.error("VM stopped with error: \(error.localizedDescription)"); exit(1)
    }
}
