import XCTest
@testable import FusionBrowser

// Issue #25: screenshot push stream. The hub is pure bookkeeping (subscribers +
// throttle + in-flight skip + end), driven by a fake capturable and a fake clock so
// the whole contract is deterministic under swift test (ARCH-3: no live WKWebView).
final class StreamHubTests: XCTestCase {
    final class FakeCapturable: FBStreamCapturable {
        var captures = 0
        var png: Data? = Data([0x89, 0x50, 0x4E, 0x47])
        var autoComplete = true
        var pending: ((Data?) -> Void)?
        var info = (url: "https://example.com/login", title: "Login")

        func screenshotPngAsync(_ completion: @escaping (Data?) -> Void) {
            captures += 1
            if autoComplete { completion(png) } else { pending = completion }
        }

        func currentPageInfo() -> (url: String, title: String) { info }
    }

    private var clock: Double = 1_000
    private func makeHub(minIntervalMs: Int = 200) -> FBStreamHub {
        FBStreamHub(minIntervalMs: minIntervalMs) { [self] in clock }
    }

    private func decoded(_ data: Data) -> [String: Any]? {
        var body = data
        guard body.count > 4 else { return nil }
        body = body.subdata(in: 4..<body.count)
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    func testTwoSubscribersReceiveSameFrame() {
        let hub = makeHub()
        var a: [Data] = []
        var b: [Data] = []
        let countA = hub.subscribe(sessionId: "s1", key: "conn-a") { a.append($0) }
        let countB = hub.subscribe(sessionId: "s1", key: "conn-b") { b.append($0) }
        XCTAssertEqual(countA, 1)
        XCTAssertEqual(countB, 2)
        hub.publish(sessionId: "s1", webview: FakeCapturable())

        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(a.first, b.first, "both subscribers see the same encoded frame")
        let frame = decoded(a[0])
        XCTAssertEqual(frame?["type"] as? String, "screenshot_frame")
        XCTAssertEqual(frame?["session_id"] as? String, "s1")
        XCTAssertEqual(frame?["seq"] as? Int, 1)
        XCTAssertEqual(frame?["url"] as? String, "https://example.com/login")
        XCTAssertEqual(frame?["title"] as? String, "Login")
        XCTAssertNotNil(frame?["png"] as? String, "png is base64 on the wire")
    }

    func testThrottleDropsFrameInsideWindow() {
        let hub = makeHub(minIntervalMs: 200)
        var received: [Data] = []
        _ = hub.subscribe(sessionId: "s1", key: "conn-a") { received.append($0) }
        let wv = FakeCapturable()

        hub.publish(sessionId: "s1", webview: wv)
        clock += 0.05
        hub.publish(sessionId: "s1", webview: wv)
        XCTAssertEqual(wv.captures, 1, "second publish inside the 200ms window is dropped")
        XCTAssertEqual(received.count, 1)

        clock += 0.20
        hub.publish(sessionId: "s1", webview: wv)
        XCTAssertEqual(wv.captures, 2)
        XCTAssertEqual(received.count, 2)
    }

    func testInFlightCaptureSkipsSecondPublish() {
        let hub = makeHub(minIntervalMs: 0)
        var received: [Data] = []
        _ = hub.subscribe(sessionId: "s1", key: "conn-a") { received.append($0) }
        let wv = FakeCapturable()
        wv.autoComplete = false

        hub.publish(sessionId: "s1", webview: wv)
        clock += 1
        hub.publish(sessionId: "s1", webview: wv)
        XCTAssertEqual(wv.captures, 1, "a capture already in flight is not restarted")
        XCTAssertTrue(received.isEmpty)

        wv.pending?(wv.png)
        XCTAssertEqual(received.count, 1)

        clock += 1
        hub.publish(sessionId: "s1", webview: wv)
        XCTAssertEqual(wv.captures, 2, "after completion a new publish captures again")
    }

    func testEndEmitsOneStreamEndThenNoMoreFrames() {
        let hub = makeHub(minIntervalMs: 0)
        var received: [Data] = []
        _ = hub.subscribe(sessionId: "s1", key: "conn-a") { received.append($0) }
        _ = hub.subscribe(sessionId: "s1", key: "conn-b") { received.append($0) }
        let wv = FakeCapturable()

        hub.end(sessionId: "s1", reason: "session_closed")
        XCTAssertEqual(received.count, 2, "one stream_end per subscriber")
        let end = decoded(received[0])
        XCTAssertEqual(end?["type"] as? String, "stream_end")
        XCTAssertEqual(end?["session_id"] as? String, "s1")
        XCTAssertEqual(end?["reason"] as? String, "session_closed")

        clock += 1
        hub.publish(sessionId: "s1", webview: wv)
        XCTAssertEqual(wv.captures, 0, "no capture after the stream ended")
        XCTAssertFalse(hub.hasSubscribers(sessionId: "s1"))
        XCTAssertEqual(received.count, 2, "no frames after stream_end")
    }

    func testUnsubscribeAllRemovesConnection() {
        let hub = makeHub()
        var received: [Data] = []
        _ = hub.subscribe(sessionId: "s1", key: "conn-a") { received.append($0) }
        _ = hub.subscribe(sessionId: "s2", key: "conn-a") { received.append($0) }
        _ = hub.subscribe(sessionId: "s1", key: "conn-b") { received.append($0) }
        XCTAssertTrue(hub.hasSubscribers(sessionId: "s1"))

        hub.unsubscribeAll(key: "conn-a")
        XCTAssertTrue(hub.hasSubscribers(sessionId: "s1"), "conn-b still subscribed")
        XCTAssertFalse(hub.hasSubscribers(sessionId: "s2"))

        let wv = FakeCapturable()
        hub.publish(sessionId: "s2", webview: wv)
        XCTAssertEqual(wv.captures, 0)
        hub.publish(sessionId: "s1", webview: wv)
        XCTAssertEqual(received.count, 1, "only conn-b's stream receives the frame")
    }

    func testUnsubscribeSingleConnectionKeepsOthers() {
        let hub = makeHub()
        var a: [Data] = []
        var b: [Data] = []
        _ = hub.subscribe(sessionId: "s1", key: "conn-a") { a.append($0) }
        _ = hub.subscribe(sessionId: "s1", key: "conn-b") { b.append($0) }
        hub.unsubscribe(sessionId: "s1", key: "conn-a")
        hub.publish(sessionId: "s1", webview: FakeCapturable())
        XCTAssertEqual(a.count, 0)
        XCTAssertEqual(b.count, 1)
    }
}
