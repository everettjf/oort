import Foundation
import Virtualization

/// Builds a `VZVirtualMachineConfiguration` from our `Config`.
///
/// This is the heart of the "Swift + VZ boots Linux" half of Stage 1. Every
/// device added here mirrors what OrbStack/Lima wire up under the hood:
///   - virtio-block  : the root disk
///   - virtio-net    : NAT networking (outbound + host reachability)
///   - virtio-vsock  : the host<->guest channel we tunnel the Docker socket over
///   - virtio-entropy / memory balloon : standard hygiene
///   - virtio-console: serial console for debugging
enum VMConfig {
    static func make(_ cfg: Config) throws -> VZVirtualMachineConfiguration {
        let vm = VZVirtualMachineConfiguration()
        vm.cpuCount = clampCPU(cfg.cpuCount)
        vm.memorySize = clampMemory(cfg.memoryBytes)

        vm.platform = VZGenericPlatformConfiguration()
        vm.bootLoader = try makeBootLoader(cfg.boot)

        vm.storageDevices = [try makeDisk(cfg.diskImage)]
        vm.networkDevices = [makeNAT()]
        vm.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vm.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        vm.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        if cfg.serialConsole {
            vm.serialPorts = [makeConsole()]
        }

        try vm.validate()
        return vm
    }

    // MARK: - Boot

    private static func makeBootLoader(_ boot: Config.Boot) throws -> VZBootLoader {
        switch boot {
        case .efi(let nvram):
            let loader = VZEFIBootLoader()
            loader.variableStore = try efiVariableStore(at: nvram)
            return loader

        case .kernel(let kernel, let initrd, let cmdline):
            guard FileManager.default.fileExists(atPath: kernel.path) else {
                throw CLIError.runtime("kernel not found: \(kernel.path)")
            }
            let loader = VZLinuxBootLoader(kernelURL: kernel)
            loader.commandLine = cmdline
            if let initrd { loader.initialRamdiskURL = initrd }
            return loader
        }
    }

    private static func efiVariableStore(at url: URL) throws -> VZEFIVariableStore {
        if FileManager.default.fileExists(atPath: url.path) {
            return VZEFIVariableStore(url: url)
        }
        Log.info("creating EFI NVRAM store at \(url.path)")
        return try VZEFIVariableStore(creatingVariableStoreAt: url)
    }

    // MARK: - Devices

    private static func makeDisk(_ url: URL) throws -> VZStorageDeviceConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.runtime("disk image not found: \(url.path)")
        }
        let attachment = try VZDiskImageStorageDeviceAttachment(url: url, readOnly: false)
        return VZVirtioBlockDeviceConfiguration(attachment: attachment)
    }

    private static func makeNAT() -> VZVirtioNetworkDeviceConfiguration {
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        return net
    }

    private static func makeConsole() -> VZVirtioConsoleDeviceSerialPortConfiguration {
        let port = VZVirtioConsoleDeviceSerialPortConfiguration()
        port.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: FileHandle.standardInput,
            fileHandleForWriting: FileHandle.standardOutput
        )
        return port
    }

    // MARK: - Clamping

    private static func clampCPU(_ requested: Int) -> Int {
        let lo = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        let hi = VZVirtualMachineConfiguration.maximumAllowedCPUCount
        return min(max(requested, lo), hi)
    }

    private static func clampMemory(_ requested: UInt64) -> UInt64 {
        let lo = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let hi = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        return min(max(requested, lo), hi)
    }
}
