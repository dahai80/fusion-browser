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
        let (frames, overflow) = reader.append(combined)
        XCTAssertEqual(frames.count, 2)
        XCTAssertFalse(overflow)
    }

    func testFrameReaderOverflowBackpressure() {
        let reader = FBFrameReader(maxFrameBytes: 16)
        // craft a frame claiming huge length
        var big = Data([0x01, 0x00, 0x00, 0x00]) // length 16M+ overflow threshold via >cap
        var len = UInt32(999_999).bigEndian
        withUnsafeBytes(of: &len) { big.append(contentsOf: $0) }
        big.append(Data(count: 999_999))
        let (frames, overflow) = reader.append(big)
        XCTAssertTrue(overflow)
        XCTAssertTrue(frames.isEmpty)
    }
}
