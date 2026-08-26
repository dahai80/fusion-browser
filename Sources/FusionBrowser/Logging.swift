import Foundation
import os

public enum FBLogLevel: Int {
    case debug = 0
    case info = 1
    case warn = 2
    case error = 3
}

public final class FBLogger {
    public static let shared = FBLogger()

    private let osLog: OSLog
    private let queue = DispatchQueue(label: "fusion-browser.logger")
    private var minLevel: FBLogLevel = .info
    private var sink: ((FBLogLevel, String, String) -> Void)?

    private init() {
        let subsystem = "com.fusion.browser"
        self.osLog = OSLog(subsystem: subsystem, category: "engine")
        // Default stderr sink so logs surface in terminal/CI (os_log only goes to Console.app).
        self.sink = { level, tag, line in
            let prefix: String
            switch level {
            case .debug: prefix = "DEBUG"
            case .info: prefix = "INFO"
            case .warn: prefix = "WARN"
            case .error: prefix = "ERROR"
            }
            FileHandle.standardError.write(Data("[\(prefix)] \(line)\n".utf8))
        }
    }

    public func setMinLevel(_ level: FBLogLevel) {
        queue.sync { minLevel = level }
    }

    public func setSink(_ sink: @escaping (FBLogLevel, String, String) -> Void) {
        queue.sync { self.sink = sink }
    }

    public func log(_ level: FBLogLevel, _ tag: String, _ message: String,
                    traceId: String? = nil, sessionId: String? = nil) {
        var prefix = ""
        if let t = traceId { prefix += "[trace=\(t)] " }
        if let s = sessionId { prefix += "[sess=\(s)] " }
        let line = "[\(tag)] \(prefix)\(message)"
        let current: FBLogLevel = queue.sync { minLevel }
        guard level.rawValue >= current.rawValue else { return }
        let type: OSLogType
        switch level {
        case .debug: type = .debug
        case .info: type = .info
        case .warn: type = .default
        case .error: type = .error
        }
        os_log("%{public}@", log: osLog, type: type, line)
        queue.sync {
            sink?(level, tag, line)
        }
    }

    public func debug(_ tag: String, _ msg: String, traceId: String? = nil, sessionId: String? = nil) {
        log(.debug, tag, msg, traceId: traceId, sessionId: sessionId)
    }
    public func info(_ tag: String, _ msg: String, traceId: String? = nil, sessionId: String? = nil) {
        log(.info, tag, msg, traceId: traceId, sessionId: sessionId)
    }
    public func warn(_ tag: String, _ msg: String, traceId: String? = nil, sessionId: String? = nil) {
        log(.warn, tag, msg, traceId: traceId, sessionId: sessionId)
    }
    public func error(_ tag: String, _ msg: String, traceId: String? = nil, sessionId: String? = nil) {
        log(.error, tag, msg, traceId: traceId, sessionId: sessionId)
    }
}
