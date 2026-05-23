import Foundation

/// Runtime configuration parsed from CLI flags. Stage-1 favours explicit paths
/// over magic auto-discovery so the moving parts stay visible.
struct Config {
    enum Boot {
        /// EFI boot directly from a bootable raw disk image (easiest: reuse a
        /// distro cloud image). Requires an NVRAM variable store on disk.
        case efi(nvram: URL)
        /// Direct kernel boot. More work to assemble matching kernel/initrd/rootfs,
        /// but gives a serial console from the very first instruction (great for debugging).
        case kernel(kernel: URL, initrd: URL?, cmdline: String)
    }

    var diskImage: URL
    var boot: Boot
    var cpuCount: Int
    var memoryBytes: UInt64
    /// vsock port inside the guest where dockerd is exposed (see guest/ setup).
    var guestVsockPort: UInt32
    /// Unix socket on macOS that the Docker CLI will talk to.
    var hostSocketPath: String
    /// Attach the guest console to this process's stdio for debugging.
    var serialConsole: Bool

    static func defaultSocketPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".openorb/docker.sock").path
    }

    static func usage() -> String {
        """
        openorb — Stage 1 skeleton: boot a Linux VM (Virtualization.framework) and
                  project the guest Docker socket onto a macOS Unix socket via vsock.

        USAGE:
          openorb run --disk <path.img> [options]

        BOOT (pick one; defaults to EFI):
          --disk <path>            Bootable raw disk image (required)
          --nvram <path>           EFI variable store path (default: <disk>.nvram)
          --kernel <path>          Direct kernel boot: kernel Image (switches off EFI)
          --initrd <path>          Initial ramdisk for kernel boot (optional)
          --cmdline <string>       Kernel command line
                                   (default: "console=hvc0 root=/dev/vda rw")

        RESOURCES:
          --cpus <n>               vCPU count (default: 4)
          --memory <GiB>           Memory in GiB (default: 4)

        DOCKER PROJECTION:
          --vsock-port <n>         Guest vsock port serving dockerd (default: 2375)
          --socket <path>          Host Unix socket (default: ~/.openorb/docker.sock)

        MISC:
          --no-console             Don't attach the guest serial console to stdio
          -h, --help               Show this help

        After it boots, point the Docker CLI at the projected socket:
          export DOCKER_HOST=unix://<socket>
          docker ps
        """
    }

    static func parse(_ args: [String]) throws -> Config {
        var it = args.makeIterator()
        guard let sub = it.next(), sub == "run" else {
            throw CLIError.usage("expected subcommand 'run'")
        }

        var disk: URL?
        var nvram: URL?
        var kernel: URL?
        var initrd: URL?
        var cmdline = "console=hvc0 root=/dev/vda rw"
        var cpus = 4
        var memGiB = 4.0
        var vsockPort: UInt32 = 2375
        var socketPath = defaultSocketPath()
        var console = true

        func need(_ name: String) throws -> String {
            guard let v = it.next() else { throw CLIError.usage("\(name) requires a value") }
            return v
        }

        while let arg = it.next() {
            switch arg {
            case "--disk":       disk = URL(fileURLWithPath: try need(arg))
            case "--nvram":      nvram = URL(fileURLWithPath: try need(arg))
            case "--kernel":     kernel = URL(fileURLWithPath: try need(arg))
            case "--initrd":     initrd = URL(fileURLWithPath: try need(arg))
            case "--cmdline":    cmdline = try need(arg)
            case "--cpus":       cpus = Int(try need(arg)) ?? cpus
            case "--memory":     memGiB = Double(try need(arg)) ?? memGiB
            case "--vsock-port": vsockPort = UInt32(try need(arg)) ?? vsockPort
            case "--socket":     socketPath = try need(arg)
            case "--no-console": console = false
            case "-h", "--help": throw CLIError.help
            default:             throw CLIError.usage("unknown argument: \(arg)")
            }
        }

        guard let disk else { throw CLIError.usage("--disk is required") }

        let boot: Boot
        if let kernel {
            boot = .kernel(kernel: kernel, initrd: initrd, cmdline: cmdline)
        } else {
            boot = .efi(nvram: nvram ?? disk.appendingPathExtension("nvram"))
        }

        return Config(
            diskImage: disk,
            boot: boot,
            cpuCount: cpus,
            memoryBytes: UInt64(memGiB * 1024 * 1024 * 1024),
            guestVsockPort: vsockPort,
            hostSocketPath: socketPath,
            serialConsole: console
        )
    }
}

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case help
    case runtime(String)

    var description: String {
        switch self {
        case .usage(let m): return "argument error: \(m)"
        case .help:         return Config.usage()
        case .runtime(let m): return m
        }
    }
}
