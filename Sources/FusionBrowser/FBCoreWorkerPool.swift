import Foundation

// PRD §4.2 Rust Worker Pool: bounded N-worker pool for the Rust core compile.
// The Rust fb_core_compile is pure stateless FFI (no statics, no locks, fresh
// alloc per call — see rust/fb-core/src/lib.rs), so it is already safe under
// concurrent calls. The pool's job is BOUNDED concurrency: cap parallel Rust
// compiles at N=cores-2 so a full FR-08 load (up to 16 sessions) cannot
// over-subscribe the CPU via the unbounded DispatchQueue.global() path the
// ActionDriver watchdog uses (ActionDriver.swift:93). Workers are dedicated
// threads pulling from a FIFO serial queue; callers block on a per-task
// semaphore until a worker returns the result.
//
// Degrade visibly (Rule 12): if enqueue/worker fails, callers fall back to an
// inline synchronous compile (the pre-pool path) — the pool is a performance
// guard, never a correctness dependency. Default off (only used when
// useRustCore is set, same gate as the Rust path itself).
public final class FBCoreWorkerPool {
    public static let shared = FBCoreWorkerPool()

    private let log = FBLogger.shared
    private let workerCount: Int
    private let workers: DispatchQueue
    private let available: DispatchSemaphore
    private var shutdown = false
    private let stateLock = NSLock()
    private var activeWorkers = 0
    private var enqueued = 0

    private init() {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        // N = cores - 2 (leave cores for the main run loop + WebContent). Floor 2.
        let n = max(2, cores - 2)
        self.workerCount = n
        // workers = concurrent queue the pool runs compiles on. The available
        // semaphore caps how many run at once (bounded concurrency); GCD picks
        // which queued block runs next (no strict FIFO, but each caller waits on
        // its own done semaphore, so order does not affect correctness).
        self.workers = DispatchQueue(label: "fusion-browser.rust-pool.workers", attributes: .concurrent)
        self.available = DispatchSemaphore(value: n)
        log.info("RustPool", "worker pool init workers=\(n) cores=\(cores)")
    }

    public var capacity: Int { workerCount }

    // Snapshot for FR-12 observability: workers, active compiles, queued.
    public func snapshot() -> [String: Int] {
        stateLock.lock()
        let active = activeWorkers
        let pending = enqueued - activeWorkers
        stateLock.unlock()
        return ["workers": workerCount, "active": active, "pending": pending]
    }

    // Compile walker JSON through a pool worker. Blocks the caller until a worker
    // finishes. Returns nil on any pool failure (caller falls back to inline).
    public func compile(_ data: Data) -> (markdown: String, nodes: [AXTreeNode], audit: SecurityAuditResult)? {
        stateLock.lock()
        if shutdown {
            stateLock.unlock()
            log.warn("RustPool", "pool shutdown; inline fallback")
            return FBCoreBridge.compileJSON(data)
        }
        enqueued += 1
        stateLock.unlock()

        FBMetrics.shared.increment("rustpool.enqueued")

        let done = DispatchSemaphore(value: 0)
        var result: (markdown: String, nodes: [AXTreeNode], audit: SecurityAuditResult)?

        // Submit on the concurrent workers queue; the semaphore caps parallelism.
        workers.async {
            self.available.wait()
            self.stateLock.lock()
            self.activeWorkers += 1
            self.stateLock.unlock()
            FBMetrics.shared.increment("rustpool.active")

            let startTs = Date().timeIntervalSince1970
            result = FBCoreBridge.compileJSON(data)
            let ms = Int((Date().timeIntervalSince1970 - startTs) * 1000)
            FBMetrics.shared.recordLatency("rustpool.compile", ms: ms)
            FBMetrics.shared.increment("rustpool.completed")
            if result == nil {
                FBMetrics.shared.increment("rustpool.fallback")
            }

            self.stateLock.lock()
            self.activeWorkers -= 1
            self.enqueued -= 1
            self.stateLock.unlock()
            self.available.signal()
            done.signal()
        }

        // Block caller until the worker returns. extract() is synchronous.
        done.wait()
        return result
    }

    // Shutdown: stop accepting new work. In-flight compiles finish. Test helper.
    public func shutdownPool() {
        stateLock.lock()
        shutdown = true
        stateLock.unlock()
        log.info("RustPool", "pool shutdown requested workers=\(workerCount)")
    }

    // Reset shutdown for test reuse (does NOT reset in-flight work).
    public func resetForTest() {
        stateLock.lock()
        shutdown = false
        activeWorkers = 0
        enqueued = 0
        stateLock.unlock()
    }
}
