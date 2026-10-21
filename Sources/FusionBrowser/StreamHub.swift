import Foundation

// Issue #25: server-pushed screenshot stream for cowork's web side panel.
// cowork subscribes on a DIRECT long-lived UDS connection (fusion-gateway dials a new
// connection per op, so it cannot hold subscriptions). Frames are their own envelope
// type (`screenshot_frame`) so a client that never subscribed sees only FBResponses.
// Two rate guards keep capture cost bounded: a per-session min interval (default
// 200ms) and an in-flight skip (a slow snapshot never queues a second capture). `end`
// is terminal for a session: one `stream_end` per subscriber, then no further frames.

public protocol FBStreamCapturable: AnyObject {
    func screenshotPngAsync(_ completion: @escaping (Data?) -> Void)
    func currentPageInfo() -> (url: String, title: String)
}

public final class FBStreamHub {
    private struct Subscriber {
        let key: String
        let send: (Data) -> Void
    }

    private let lock = NSLock()
    private var subscribers: [String: [Int: Subscriber]] = [:]
    private var nextSubId = 1
    private var seqBySession: [String: Int] = [:]
    private var lastCaptureAt: [String: Double] = [:]
    private var inFlight: Set<String> = []
    private let minIntervalMs: Int
    private let now: () -> Double
    private let log = FBLogger.shared

    public init(minIntervalMs: Int = 200,
                now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.minIntervalMs = minIntervalMs
        self.now = now
    }

    // Returns the subscriber count for the session after adding this one. Idempotent per
    // connection: a repeated `enabled:true` from the same key REPLACES that key's entry
    // (a retrying panel must not stack N copies of its own stream — each copy is another
    // full PNG written to the same fd on every action).
    @discardableResult
    public func subscribe(sessionId: String, key: String, send: @escaping (Data) -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        var subs = (subscribers[sessionId] ?? [:]).filter { $0.value.key != key }
        let id = nextSubId
        nextSubId += 1
        subs[id] = Subscriber(key: key, send: send)
        subscribers[sessionId] = subs
        log.info("Stream", "subscribed session=\(sessionId) key=\(key.prefix(8)) listeners=\(subs.count)")
        return subs.count
    }

    public func unsubscribe(sessionId: String, key: String) {
        lock.lock()
        var subs = subscribers[sessionId] ?? [:]
        subs = subs.filter { $0.value.key != key }
        if subs.isEmpty { subscribers.removeValue(forKey: sessionId) } else { subscribers[sessionId] = subs }
        lock.unlock()
        log.info("Stream", "unsubscribed session=\(sessionId) key=\(key.prefix(8))")
    }

    // Connection teardown: drop every subscription this connection held.
    public func unsubscribeAll(key: String) {
        lock.lock()
        var removed = 0
        for (sessionId, subs) in subscribers {
            let kept = subs.filter { $0.value.key != key }
            removed += subs.count - kept.count
            if kept.isEmpty { subscribers.removeValue(forKey: sessionId) } else { subscribers[sessionId] = kept }
        }
        lock.unlock()
        if removed > 0 { log.info("Stream", "unsubscribeAll key=\(key.prefix(8)) removed=\(removed)") }
    }

    public func hasSubscribers(sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !(subscribers[sessionId]?.isEmpty ?? true)
    }

    public func publish(sessionId: String, webview: any FBStreamCapturable) {
        lock.lock()
        guard let subs = subscribers[sessionId], !subs.isEmpty else { lock.unlock(); return }
        if inFlight.contains(sessionId) {
            lock.unlock()
            log.debug("Stream", "publish skipped (capture in flight) session=\(sessionId)")
            return
        }
        let t = now()
        if let last = lastCaptureAt[sessionId], (t - last) * 1000.0 < Double(minIntervalMs) {
            lock.unlock()
            log.debug("Stream", "publish throttled session=\(sessionId)")
            return
        }
        inFlight.insert(sessionId)
        lastCaptureAt[sessionId] = t
        lock.unlock()

        let info = webview.currentPageInfo()
        webview.screenshotPngAsync { [weak self] png in
            guard let self = self else { return }
            self.lock.lock()
            self.inFlight.remove(sessionId)
            guard let png = png else {
                self.lock.unlock()
                self.log.warn("Stream", "capture returned no png session=\(sessionId)")
                return
            }
            let seq = (self.seqBySession[sessionId] ?? 0) + 1
            self.seqBySession[sessionId] = seq
            let targets = Array((self.subscribers[sessionId] ?? [:]).values)
            self.lock.unlock()
            guard !targets.isEmpty else { return }
            let event = ScreenshotFrameEvent(sessionId: sessionId, seq: seq, png: png,
                                             url: info.url, title: info.title,
                                             tsMs: Int(self.now() * 1000))
            guard let data = try? FBFrame.encode(event) else {
                self.log.error("Stream", "frame encode failed session=\(sessionId)")
                return
            }
            for sub in targets { sub.send(data) }
            self.log.debug("Stream", "frame sent session=\(sessionId) seq=\(seq) bytes=\(png.count) listeners=\(targets.count)")
        }
    }

    // Terminal for the session's stream: one stream_end per subscriber, then the
    // session's subscriptions are gone (a later publish captures nothing).
    public func end(sessionId: String, reason: String) {
        lock.lock()
        let subs = subscribers.removeValue(forKey: sessionId)
        seqBySession.removeValue(forKey: sessionId)
        lastCaptureAt.removeValue(forKey: sessionId)
        inFlight.remove(sessionId)
        lock.unlock()
        guard let subs = subs, !subs.isEmpty else { return }
        let event = StreamEndEvent(sessionId: sessionId, reason: reason)
        guard let data = try? FBFrame.encode(event) else {
            log.error("Stream", "stream_end encode failed session=\(sessionId)")
            return
        }
        for sub in subs.values { sub.send(data) }
        log.info("Stream", "ended session=\(sessionId) reason=\(reason) listeners=\(subs.count)")
    }
}
