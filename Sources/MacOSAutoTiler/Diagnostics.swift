import Foundation

enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

enum Diagnostics {
    private static let formatter = ISO8601DateFormatter()

    static let isVerbose: Bool = {
        let env = ProcessInfo.processInfo.environment["TILER_DEBUG"]?.lowercased()
        if let env {
            return env != "0" && env != "false" && env != "off"
        }
        return true
    }()

    static func log(
        _ message: @autoclosure () -> String,
        level: LogLevel = .info,
        force: Bool = false
    ) {
        if level == .debug && !isVerbose && !force {
            return
        }
        let ts = formatter.string(from: Date())
        print("[Tiler][\(ts)][\(level.rawValue)] \(message())")
    }
}
