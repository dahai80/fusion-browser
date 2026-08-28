import Foundation

// FR-12: metrics + trace id + credential audit log.
// Trace id threads agent-studio -> browser -> mlx (passed in BrowserActionRequest.traceId).

public final class FBMetrics {
    public static let shared = FBMetrics()
    private let queue = DispatchQueue(label: "fusion-browser.metrics")
    private var counters: [String: Int] = [:]
    private var latencySamples: [String: [Int]] = [:]
    private let maxSamples = 1000

    private init() {}

    public func increment(_ key: String, by n: Int = 1) {
        queue.sync { counters[key, default: 0] += n }
    }

    public func recordLatency(_ key: String, ms: Int) {
        queue.sync {
            var arr = latencySamples[key] ?? []
            arr.append(ms)
            if arr.count > maxSamples { arr.removeFirst(arr.count - maxSamples) }
            latencySamples[key] = arr
        }
    }

    public func snapshot() -> [String: Any] {
        return queue.sync {
            var lat: [String: [String: Int]] = [:]
            for (k, v) in latencySamples where !v.isEmpty {
                let sorted = v.sorted()
                let p50 = sorted[sorted.count / 2]
                let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                lat[k] = ["count": v.count, "p50": p50, "p95": p95]
            }
            return ["counters": counters, "latency": lat]
        }
    }

    // R-3/B-3: CDP-shaped metrics array for Performance.getMetrics + UDS metrics response.
    // Each counter -> {name,value}; each latency key -> count/p50/p95 triple. Flat list
    // (no nesting) so it round-trips through JSONEncoder cleanly ([String:Any] with nested
    // dicts does NOT encode with Foundation without casting). Returns a Codable struct array.
    public struct FBMetric: Codable {
        public var name: String
        public var value: Double
    }

    public func metricsArray() -> [FBMetric] {
        return queue.sync {
            var out: [FBMetric] = []
            for (k, v) in counters {
                out.append(FBMetric(name: k, value: Double(v)))
            }
            for (k, v) in latencySamples where !v.isEmpty {
                let sorted = v.sorted()
                let p50 = sorted[sorted.count / 2]
                let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                out.append(FBMetric(name: "\(k).count", value: Double(v.count)))
                out.append(FBMetric(name: "\(k).p50_ms", value: Double(p50)))
                out.append(FBMetric(name: "\(k).p95_ms", value: Double(p95)))
            }
            return out
        }
    }
}

public final class FBCredentialAuditLog {
    public static let shared = FBCredentialAuditLog()
    private let queue = DispatchQueue(label: "fusion-browser.credaudit")
    private var entries: [Entry] = []
    private let log = FBLogger.shared

    public struct Entry: Codable {
        public var ts: Double
        public var caller: String
        public var domain: String
        public var op: String
        public var result: String
    }

    private init() {}

    // No plaintext ever. op in {inject, lock, miss, logout}. result in {ok, fail, locked}.
    public func record(caller: String, domain: String, op: String, result: String) {
        let e = Entry(ts: Date().timeIntervalSince1970, caller: caller, domain: domain, op: op, result: result)
        queue.sync {
            entries.append(e)
            if entries.count > 5000 { entries.removeFirst(entries.count - 5000) }
        }
        log.info("CredAudit", "caller=\(caller) domain=\(domain) op=\(op) result=\(result)")
    }

    public func snapshot() -> [Entry] {
        return queue.sync { entries }
    }
}

public enum FBTrace {
    // Generate trace id when caller omits one.
    public static func newId() -> String {
        let bytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
