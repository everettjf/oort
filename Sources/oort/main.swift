import Foundation

// Entry point. VZ delivers its callbacks on the VM queue, but the process still
// needs a live run loop — so we start everything and then park on dispatchMain().

let args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty {
    print(Config.usage())
    exit(args.isEmpty ? 1 : 0)
}

do {
    let cfg = try Config.parse(args)
    let manager = VMManager(cfg)

    // Graceful Ctrl-C: ask the guest to shut down cleanly.
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler {
        Log.info("SIGINT — requesting guest stop…")
        manager.requestStop()
    }
    sigint.resume()
    signal(SIGINT, SIG_IGN) // hand control to the dispatch source

    try manager.startAndProject()
    dispatchMain()
} catch CLIError.help {
    print(Config.usage())
    exit(0)
} catch {
    Log.error("\(error)")
    exit(1)
}
