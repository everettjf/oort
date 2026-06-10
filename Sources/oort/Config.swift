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

    /// A host directory shared into the guest over VirtioFS, addressed by `tag`.
    struct Mount {
        var host: URL
        var tag: String
        var readOnly: Bool
    }

    var diskImage: URL
    var boot: Boot
    var cpuCount: Int
    var memoryBytes: UInt64
    /// Host directories shared into the guest via VirtioFS (Stage 2).
    var mounts: [Mount]
    /// Share Rosetta into the guest so x86-64 binaries/containers run (Stage 2).
    var rosetta: Bool
    /// Extra vsock forwards: a host Unix socket ⇄ a guest vsock port (Stage 3).
    struct Forward { var socketPath: String; var guestPort: UInt32 }
    var forwards: [Forward]
    /// Auto-forward container-published ports to the macOS localhost (Stage 3).
    var portForward: Bool
    /// Always-on localhost→guest TCP forwards (e.g. the k3s API on 6443, or
    /// sshd as 2222:22) (M6/M11). hostPort on 127.0.0.1 ⇄ guestPort in the guest.
    struct TCPForward: Hashable { var hostPort: Int; var guestPort: Int }
    var tcpForwards: [TCPForward]
    /// Active memory ballooning: return idle guest memory to macOS (M3).
    var dynamicMemory: Bool
    /// `*.oort.local` DNS responder for container/machine domains (M7).
    /// 0 disables; macOS dispatches the queries via /etc/resolver/oort.local.
    var dnsPort: UInt16
    /// vsock port inside the guest where dockerd is exposed (see guest/ setup).
    var guestVsockPort: UInt32
    /// Unix socket on macOS that the Docker CLI will talk to.
    var hostSocketPath: String
    /// Attach the guest console to this process's stdio for debugging.
    var serialConsole: Bool
    /// Optional second read-only disk (e.g. a cloud-init NoCloud CIDATA image).
    var seedImage: URL?
    /// If set, write the guest serial console to this file (headless debugging).
    var consoleLog: URL?
    /// If set and the file exists, restore the whole VM from this suspended-state
    /// file instead of cold-booting (M8); falls back to a cold boot on failure.
    /// SIGUSR1 suspends the VM back to this path.
    var restoreState: URL?
    /// If set, attach the guest NIC to this gvproxy vfkit unixgram socket (a
    /// user-space network stack on the host) instead of VZ NAT. The guest's
    /// traffic then flows through macOS's own stack — following VPN/DNS — and
    /// containers/machines become reachable by IP. Default: nil (VZ NAT).
    var netVfkitSocket: String?

    static func defaultSocketPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".oort/docker.sock").path
    }

    static func usage() -> String {
        """
        oort — Stage 1 skeleton: boot a Linux VM (Virtualization.framework) and
                  project the guest Docker socket onto a macOS Unix socket via vsock.

        USAGE:
          oort run --disk <path.img> [options]

        BOOT (pick one; defaults to EFI):
          --disk <path>            Bootable raw disk image (required)
          --seed <path>            Extra read-only disk, e.g. cloud-init CIDATA image
          --nvram <path>           EFI variable store path (default: <disk>.nvram)
          --kernel <path>          Direct kernel boot: kernel Image (switches off EFI)
          --initrd <path>          Initial ramdisk for kernel boot (optional)
          --cmdline <string>       Kernel command line
                                   (default: "console=hvc0 root=/dev/vda rw")

        RESOURCES:
          --cpus <n>               vCPU count (default: 4)
          --memory <GiB>           Memory in GiB (default: 4)

        FILE SHARING (Stage 2, VirtioFS):
          --mount <hostdir>[:tag]  Share a host dir into the guest (repeatable).
                                   Default tag for the first mount is "mac"
                                   (the guest mounts it at /mnt/<tag>).
          --rosetta                Share Rosetta into the guest so x86-64 images
                                   run via translation (installs Rosetta if needed).

        DOCKER PROJECTION:
          --vsock-port <n>         Guest vsock port serving dockerd (default: 2375)
          --socket <path>          Host Unix socket (default: ~/.oort/docker.sock)
          --forward <sock>:<port>  Extra host-socket ⇄ guest-vsock-port forward
                                   (repeatable; e.g. a debug agent on port 2376).
          --net-vfkit <sock>       Use a gvproxy user-space netstack on this vfkit
                                   unixgram socket instead of VZ NAT (VPN/DNS-
                                   following egress, container reachability).
          --no-port-forward        Don't auto-forward container ports to localhost.
          --no-dynamic-memory      Don't actively balloon idle guest memory back.
          --dns-port <n>           UDP port for the *.oort.local resolver on
                                   127.0.0.1 (default: 5354; 0 disables).
          --state <path>           Suspend/resume state file: restore from it when
                                   it exists (else cold-boot); SIGUSR1 suspends
                                   the VM back to it and exits.

        MISC:
          --no-console             Don't attach the guest serial console to stdio
          --console-log <path>     Write the guest console to a file (headless)
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
        var seed: URL?
        var mounts: [Mount] = []
        var rosetta = false
        var forwards: [Forward] = []
        var portForward = true
        var dynamicMemory = true
        var dnsPort: UInt16 = 5354
        var tcpForwards: [TCPForward] = []
        var consoleLog: URL?
        var nvram: URL?
        var stateFile: URL?
        var netVfkit: String?
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
            case "--seed":       seed = URL(fileURLWithPath: try need(arg))
            case "--mount":      mounts.append(try parseMount(need(arg), index: mounts.count))
            case "--rosetta":    rosetta = true
            case "--forward":    forwards.append(try parseForward(need(arg)))
            case "--no-port-forward": portForward = false
            case "--no-dynamic-memory": dynamicMemory = false
            case "--dns-port":   dnsPort = UInt16(try need(arg)) ?? dnsPort
            case "--tcp-forward": tcpForwards.append(try parseTCPForward(need(arg)))
            case "--console-log": consoleLog = URL(fileURLWithPath: try need(arg))
            case "--nvram":      nvram = URL(fileURLWithPath: try need(arg))
            case "--state":      stateFile = URL(fileURLWithPath: try need(arg))
            case "--net-vfkit":  netVfkit = try need(arg)
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
            mounts: mounts,
            rosetta: rosetta,
            forwards: forwards,
            portForward: portForward,
            tcpForwards: tcpForwards,
            dynamicMemory: dynamicMemory,
            dnsPort: dnsPort,
            guestVsockPort: vsockPort,
            hostSocketPath: socketPath,
            serialConsole: console,
            seedImage: seed,
            consoleLog: consoleLog,
            restoreState: stateFile,
            netVfkitSocket: netVfkit
        )
    }

    /// Parse `--mount` specs: `hostdir`, `hostdir:tag`, or `hostdir:tag:ro`.
    /// macOS paths don't contain ':', so splitting on it is safe.
    private static func parseMount(_ spec: String, index: Int) throws -> Mount {
        let parts = spec.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard let hostPart = parts.first, !hostPart.isEmpty else {
            throw CLIError.usage("--mount needs a host directory")
        }
        let host = URL(fileURLWithPath: (hostPart as NSString).expandingTildeInPath)
        let tag = (parts.count > 1 && !parts[1].isEmpty) ? parts[1] : (index == 0 ? "mac" : "share\(index)")
        let readOnly = parts.count > 2 && parts[2] == "ro"
        return Mount(host: host, tag: tag, readOnly: readOnly)
    }

    /// Parse `--tcp-forward <port>` (same port both sides) or `<host>:<guest>`.
    private static func parseTCPForward(_ spec: String) throws -> TCPForward {
        let parts = spec.split(separator: ":").map(String.init)
        if parts.count == 1, let p = Int(parts[0]) { return TCPForward(hostPort: p, guestPort: p) }
        if parts.count == 2, let h = Int(parts[0]), let g = Int(parts[1]) {
            return TCPForward(hostPort: h, guestPort: g)
        }
        throw CLIError.usage("--tcp-forward must be <port> or <hostPort>:<guestPort>")
    }

    /// Parse `--forward <hostSocketPath>:<guestVsockPort>`.
    private static func parseForward(_ spec: String) throws -> Forward {
        guard let idx = spec.lastIndex(of: ":"),
              let port = UInt32(spec[spec.index(after: idx)...]) else {
            throw CLIError.usage("--forward must be <hostSocketPath>:<guestVsockPort>")
        }
        let path = String(spec[..<idx])
        return Forward(socketPath: (path as NSString).expandingTildeInPath, guestPort: port)
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
