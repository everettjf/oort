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

    init(_ cfg: Config) { self.cfg = cfg }

    func startAndProject() throws {
        let configuration = try VMConfig.make(cfg)
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
