import XCTest
@testable import FusionBrowser

final class FramingTests: XCTestCase {

    func testEncodeDecodeRoundTrip() throws {
        let req = FBRequest.execute(BrowserActionRequest(sessionId: "s1", action: .click, targetNodeId: "@e1"))
        let data = try FBFrame.encode(req)
        XCTAssertGreaterThan(data.count, 4)
        let json = data.subdata(in: 4..<data.count)
        let decoded = try FBFrame.decode(json, as: FBRequest.self)
        if case .execute(let r) = decoded {
            XCTAssertEqual(r.sessionId, "s1")
            XCTAssertEqual(r.action, .click)
            XCTAssertEqual(r.targetNodeId, "@e1")
        } else {
            XCTFail("expected execute")
        }
    }

    func testFrameReaderSplitsMultipleFrames() {
        let reader = FBFrameReader()
        let r1 = try! FBFrame.encode(BrowserActionRequest(sessionId: "a", action: .scroll))
        let r2 = try! FBFrame.encode(BrowserActionRequest(sessionId: "b", action: .navigate))
        let combined = r1 + r2
        let (frames, overflow, timeout) = reader.append(combined)
        XCTAssertEqual(frames.count, 2)
        XCTAssertFalse(overflow)
        XCTAssertFalse(timeout)
    }

    func testFrameReaderOverflowBackpressure() {
        let reader = FBFrameReader(maxFrameBytes: 16)
        // craft a frame claiming huge length
        var big = Data([0x01, 0x00, 0x00, 0x00]) // length 16M+ overflow threshold via >cap
        var len = UInt32(999_999).bigEndian
        withUnsafeBytes(of: &len) { big.append(contentsOf: $0) }
        big.append(Data(count: 999_999))
        let (frames, overflow, timeout) = reader.append(big)
        XCTAssertTrue(overflow)
        XCTAssertTrue(frames.isEmpty)
        XCTAssertFalse(timeout, "overflow is not a timeout")
    }

    // B-4/R-6: a partial frame (length prefix read, body incomplete) that stays
    // incomplete past frameTimeoutMs signals `timeout` and clears the buffer.
    func testFrameReaderPartialFrameTimeout() {
        let reader = FBFrameReader(maxFrameBytes: 1024, frameTimeoutMs: 50)
        // Send only the 4-byte length prefix claiming a 100-byte frame; body absent.
        var prefix = UInt32(100).bigEndian
        var partial = Data()
        withUnsafeBytes(of: &prefix) { partial.append(contentsOf: $0) }
        let (f1, ov1, to1) = reader.append(partial)
        XCTAssertTrue(f1.isEmpty, "no complete frame yet")
        XCTAssertFalse(ov1)
        XCTAssertFalse(to1, "first partial observation must NOT time out (clock just started)")
        // Wait past the 50ms budget, then drip one more byte. Still incomplete -> timeout.
        Thread.sleep(forTimeInterval: 0.08)
        let (f2, ov2, to2) = reader.append(Data([0x41]))
        XCTAssertTrue(to2, "partial frame overstayed frameTimeoutMs -> timeout signaled")
        XCTAssertTrue(f2.isEmpty, "no frames emitted on timeout")
        XCTAssertFalse(ov2)
        // Buffer cleared after timeout: a fresh complete frame decodes cleanly.
        let full = try! FBFrame.encode(BrowserActionRequest(sessionId: "fresh", action: .click))
        let (f3, ov3, to3) = reader.append(full)
        XCTAssertFalse(to3, "buffer was cleared; new frame must not inherit the stale timeout")
        XCTAssertEqual(f3.count, 1)
        XCTAssertFalse(ov3)
    }

    // B-4/R-6: a partial frame completed WITHIN the budget must NOT time out.
    func testFrameReaderPartialFrameCompletesWithinBudget() {
        let reader = FBFrameReader(maxFrameBytes: 1024, frameTimeoutMs: 500)
        var prefix = UInt32(20).bigEndian
        var partial = Data()
        withUnsafeBytes(of: &prefix) { partial.append(contentsOf: $0) }
        let (f1, _, to1) = reader.append(partial)
        XCTAssertTrue(f1.isEmpty)
        XCTAssertFalse(to1)
        // Complete the frame quickly (well under 500ms).
        let body = Data(repeating: 0x42, count: 20)
        let (f2, _, to2) = reader.append(body)
        XCTAssertFalse(to2, "frame completed within budget must not time out")
        XCTAssertEqual(f2.count, 1)
    }
}
