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
    // P-5: minLevel is read on EVERY log call (the level gate). The old code took a
    // queue.sync per read — at error level, every debug/info call still paid the sync
    // hop + the string interpolation that happened BEFORE log() was entered (Swift
    // evaluates args at the call site). Two fixes:
    //   (a) minLevel read atomically (os_unfair_lock) — no queue hop to gate, so a
    //       filtered-out level returns before touching the sink queue.
    //   (b) the sink write used a SECOND queue.sync per line; drop it. The sink itself
    //       is now guarded by sinkLock so setSink() and the sink call don't race, but a
    //       plain lock (not a serial-queue sync) is far cheaper than two sync hops/line.
    // os_log is thread-safe, so it needs no queue. The 1000-action long-run no longer
    // turns the logger into a contention point.
    private var minLevel: FBLogLevel = .info
    private var levelLock = os_unfair_lock()
    private var sink: ((FBLogLevel, String, String) -> Void)?
    private var sinkLock = os_unfair_lock()

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

    // P-5 test seam: a PRIVATE singleton would force tests to mutate .shared (setSink/
    // setMinLevel), leaking level/sink changes across the whole suite — a concurrent test
    // swapping the sink would silently break every other test's assertions. Hand out an
    // isolated instance instead so each test owns its logger. internal = test-only access.
    internal static func makeForTest() -> FBLogger {
        return FBLogger()
    }

    private func readMinLevel() -> FBLogLevel {
        os_unfair_lock_lock(&levelLock)
        let v = minLevel
        os_unfair_lock_unlock(&levelLock)
        return v
    }

    public func setMinLevel(_ level: FBLogLevel) {
        os_unfair_lock_lock(&levelLock)
        minLevel = level
        os_unfair_lock_unlock(&levelLock)
    }

    public func setSink(_ sink: @escaping (FBLogLevel, String, String) -> Void) {
        os_unfair_lock_lock(&sinkLock)
        self.sink = sink
        os_unfair_lock_unlock(&sinkLock)
    }

    public func log(_ level: FBLogLevel, _ tag: String, _ message: String,
                    traceId: String? = nil, sessionId: String? = nil) {
        // P-5: atomic level read gates BEFORE the line build — a debug call at error
        // level returns here with one cheap lock, no string work, no sink queue hop.
        guard level.rawValue >= readMinLevel().rawValue else { return }
        var prefix = ""
        if let t = traceId { prefix += "[trace=\(t)] " }
        if let s = sessionId { prefix += "[sess=\(s)] " }
        let line = "[\(tag)] \(prefix)\(message)"
        let type: OSLogType
        switch level {
        case .debug: type = .debug
        case .info: type = .info
        case .warn: type = .default
        case .error: type = .error
        }
        os_log("%{public}@", log: osLog, type: type, line)
        // P-5: sink guarded by a plain lock (no serial-queue sync). Captures no mutable
        // shared state beyond the sink closure itself; os_log already ran above.
        os_unfair_lock_lock(&sinkLock)
        let s = sink
        os_unfair_lock_unlock(&sinkLock)
        s?(level, tag, line)
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
