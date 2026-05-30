import Foundation

/// Minimal timestamped logger. Stage-1 keeps dependencies at zero on purpose.
enum Log {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ msg: String) { line("INFO", msg) }
    static func warn(_ msg: String) { line("WARN", msg) }
    static func error(_ msg: String) { line("ERR ", msg) }

    private static func line(_ level: String, _ msg: String) {
        FileHandle.standardError.write(Data("[\(formatter.string(from: Date()))] \(level) \(msg)\n".utf8))
    }
}
