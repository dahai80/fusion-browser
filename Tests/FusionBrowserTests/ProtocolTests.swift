import XCTest
@testable import FusionBrowser

// Issue #25: wire-schema additions for the cowork managed-backend surface.
// Additive only — existing types keep their shape; new types round-trip through
// the real FBFrame codec (snake_case + length prefix).
final class ProtocolTests: XCTestCase {
    private func roundtripRequest(_ req: FBRequest) throws -> FBRequest {
        let data = try FBFrame.encode(req)
        let body = data.dropFirst(4)
        return try FBFrame.decode(Data(body), as: FBRequest.self)
    }

    private func roundtripResponse(_ resp: FBResponse) throws -> FBResponse {
        let data = try FBFrame.encode(resp)
        let body = data.dropFirst(4)
        return try FBFrame.decode(Data(body), as: FBResponse.self)
    }

    func testCreateSessionProfileIdRoundtrip() throws {
        let req = FBRequest.createSession(CreateSessionRequest(mode: .headless, initialUrl: nil,
                                                               maxActions: nil, taskTimeoutMs: nil,
                                                               credentialDomain: nil, profileId: "run-42"))
        guard case .createSession(let p) = try roundtripRequest(req) else {
            return XCTFail("expected createSession")
        }
        XCTAssertEqual(p.profileId, "run-42")
    }

    func testCreateSessionWithoutProfileIdStaysNil() throws {
        let req = FBRequest.createSession(CreateSessionRequest(mode: .headless))
        guard case .createSession(let p) = try roundtripRequest(req) else {
            return XCTFail("expected createSession")
        }
        XCTAssertNil(p.profileId, "absent profile_id must decode as nil (FR-04 default path)")
    }

    func testImportCookiesRoundtrip() throws {
        let req = FBRequest.importCookies(ImportCookiesRequest(sessionId: "s1", browser: "firefox", profile: "abc.default"))
        guard case .importCookies(let p) = try roundtripRequest(req) else {
            return XCTFail("expected importCookies")
        }
        XCTAssertEqual(p.sessionId, "s1")
        XCTAssertEqual(p.browser, "firefox")
        XCTAssertEqual(p.profile, "abc.default")

        let resp = FBResponse.importCookies(ImportCookiesResponse(sessionId: "s1", browser: "firefox",
                                                                  imported: 3, skippedAppBound: 1, skippedOther: 2))
        guard case .importCookies(let r) = try roundtripResponse(resp) else {
            return XCTFail("expected importCookies response")
        }
        XCTAssertEqual(r.imported, 3)
        XCTAssertEqual(r.skippedAppBound, 1)
        XCTAssertEqual(r.skippedOther, 2)
    }

    func testStreamScreenshotsRoundtrip() throws {
        let req = FBRequest.streamScreenshots(StreamScreenshotsRequest(sessionId: "s1", enabled: true))
        guard case .streamScreenshots(let p) = try roundtripRequest(req) else {
            return XCTFail("expected streamScreenshots")
        }
        XCTAssertTrue(p.enabled)

        let resp = FBResponse.streamAck(StreamAckResponse(sessionId: "s1", active: true))
        guard case .streamAck(let r) = try roundtripResponse(resp) else {
            return XCTFail("expected streamAck")
        }
        XCTAssertTrue(r.active)
    }

    func testDeleteProfileRoundtrip() throws {
        let req = FBRequest.deleteProfile(DeleteProfileRequest(profileId: "run-42"))
        guard case .deleteProfile(let p) = try roundtripRequest(req) else {
            return XCTFail("expected deleteProfile")
        }
        XCTAssertEqual(p.profileId, "run-42")

        let resp = FBResponse.profileDeleted(ProfileDeletedResponse(profileId: "run-42", deleted: true))
        guard case .profileDeleted(let r) = try roundtripResponse(resp) else {
            return XCTFail("expected profileDeleted")
        }
        XCTAssertTrue(r.deleted)
    }

    // Push events are their own envelopes (never FBResponse): a "type" discriminator
    // plus snake_case keys. png carries base64 (Data codable default).
    func testScreenshotFrameEventShape() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let ev = ScreenshotFrameEvent(sessionId: "s1", seq: 7, png: png, url: "https://x/y", title: "t", tsMs: 1234)
        let data = try FBFrame.encode(ev)
        let obj = try JSONSerialization.jsonObject(with: data.dropFirst(4)) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "screenshot_frame")
        XCTAssertEqual(obj?["session_id"] as? String, "s1")
        XCTAssertEqual(obj?["seq"] as? Int, 7)
        XCTAssertEqual(obj?["ts_ms"] as? Int, 1234)
        XCTAssertEqual((obj?["png"] as? String).flatMap { Data(base64Encoded: $0) }, png)
    }

    func testStreamEndEventShape() throws {
        let ev = StreamEndEvent(sessionId: "s1", reason: "session_closed")
        let data = try FBFrame.encode(ev)
        let obj = try JSONSerialization.jsonObject(with: data.dropFirst(4)) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "stream_end")
        XCTAssertEqual(obj?["session_id"] as? String, "s1")
        XCTAssertEqual(obj?["reason"] as? String, "session_closed")
    }

    // Forward compat: an unknown request type must fail cleanly (throw), never decode as
    // some other case. Old server + new client relies on this being an error frame.
    func testUnknownRequestTypeThrows() {
        let body = Data("{\"type\":\"future_op\",\"payload\":{}}".utf8)
        XCTAssertThrowsError(try FBFrame.decode(body, as: FBRequest.self))
    }
}
