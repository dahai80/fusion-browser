import XCTest
@testable import FusionBrowser

// T3.4: deterministic unit tests for the visual-grounding fallback. The live VLM call
// (fusion-mlx, must real-load a model per project rule) is integration-only via the
// binary + smoke harness — not asserted here. These tests cover body building, response
// parsing, OOB guard, and the disabled path, all via a fake FBHTTPClient.

final class VisualLocatorTests: XCTestCase {

    // Fake client: returns a canned chat-completion JSON for a given assistant text,
    // or nil to simulate HTTP failure. Also captures the last posted body for assertions.
    private final class FakeHTTPClient: FBHTTPClient {
        let assistantText: String?
        var lastBody: Data? = nil
        init(assistantText: String?) { self.assistantText = assistantText }
        func post(url: String, body: Data, timeoutMs: Int) -> Data? {
            lastBody = body
            guard let text = assistantText else { return nil }
            let resp: [String: Any] = [
                "choices": [["message": ["role": "assistant", "content": text]]],
            ]
            return try? JSONSerialization.data(withJSONObject: resp)
        }
    }

    private func enabledConfig() -> FBVisualLocatorConfig {
        return FBVisualLocatorConfig(endpoint: "http://127.0.0.1:11434",
                                     model: "test-vlm", timeoutMs: 5_000, enabled: true)
    }

    func testDisabledReturnsNilAndNoCall() {
        let cfg = FBVisualLocatorConfig(enabled: false)
        let client = FakeHTTPClient(assistantText: "{\"x\":1,\"y\":2}")
        let loc = FBVisualLocator(config: cfg, client: client)
        let r = loc.predict(screenshot: Data([0x89, 0x50]), description: "login button", viewportSize: (1280, 800))
        XCTAssertNil(r)
        XCTAssertNil(client.lastBody, "disabled locator must not POST")
    }

    func testParsesPlainJSONCoords() {
        let client = FakeHTTPClient(assistantText: "{\"x\":320,\"y\":150}")
        let loc = FBVisualLocator(config: enabledConfig(), client: client)
        let r = loc.predict(screenshot: Data([0x89]), description: "submit button", viewportSize: (1280, 800))
        XCTAssertEqual(r?.x, 320)
        XCTAssertEqual(r?.y, 150)
    }

    // VLMs often wrap JSON in prose/code fences; parser must tolerate it.
    func testParsesJSONInProseAndCodeFence() {
        let client = FakeHTTPClient(assistantText: "Here is the coordinate:\n```json\n{\"x\": 42, \"y\": 88}\n```\nDone.")
        let loc = FBVisualLocator(config: enabledConfig(), client: client)
        let r = loc.predict(screenshot: Data([0x89]), description: "search box", viewportSize: (1280, 800))
        XCTAssertEqual(r?.x, 42)
        XCTAssertEqual(r?.y, 88)
    }

    // Integer coords from JSON are coerced to Double.
    func testParsesIntegerCoords() {
        let client = FakeHTTPClient(assistantText: "{\"x\":100,\"y\":200}")
        let loc = FBVisualLocator(config: enabledConfig(), client: client)
        let r = loc.predict(screenshot: Data([0x89]), description: "x", viewportSize: (1280, 800))
        XCTAssertEqual(r?.x, 100.0)
        XCTAssertEqual(r?.y, 200.0)
    }

    func testOutOfBoundsRejected() {
        let client = FakeHTTPClient(assistantText: "{\"x\":5000,\"y\":10}")
        let loc = FBVisualLocator(config: enabledConfig(), client: client)
        let r = loc.predict(screenshot: Data([0x89]), description: "x", viewportSize: (1280, 800))
        XCTAssertNil(r, "coords past viewport width must be rejected")
    }

    func testNegativeRejected() {
        let client = FakeHTTPClient(assistantText: "{\"x\":-5,\"y\":10}")
        let loc = FBVisualLocator(config: enabledConfig(), client: client)
        let r = loc.predict(screenshot: Data([0x89]), description: "x", viewportSize: (1280, 800))
        XCTAssertNil(r)
    }

    func testHTTPFailureReturnsNil() {
        let client = FakeHTTPClient(assistantText: nil)
        let loc = FBVisualLocator(config: enabledConfig(), client: client)
        let r = loc.predict(screenshot: Data([0x89]), description: "x", viewportSize: (1280, 800))
        XCTAssertNil(r)
    }

    func testUnparseableTextReturnsNil() {
        let client = FakeHTTPClient(assistantText: "I cannot find any coordinates.")
        let loc = FBVisualLocator(config: enabledConfig(), client: client)
        let r = loc.predict(screenshot: Data([0x89]), description: "x", viewportSize: (1280, 800))
        XCTAssertNil(r)
    }

    func testEmptyScreenshotOrDescriptionReturnsNil() {
        let client = FakeHTTPClient(assistantText: "{\"x\":1,\"y\":1}")
        let loc = FBVisualLocator(config: enabledConfig(), client: client)
        XCTAssertNil(loc.predict(screenshot: Data(), description: "x", viewportSize: (1280, 800)))
        XCTAssertNil(loc.predict(screenshot: Data([0x89]), description: "", viewportSize: (1280, 800)))
    }

    // The request body must carry the model, an image_url data-URI part, and a text prompt
    // naming the viewport size + description (fusion-mlx VLM engine reads image_url.url).
    func testRequestBodyShape() {
        let client = FakeHTTPClient(assistantText: "{\"x\":1,\"y\":1}")
        let loc = FBVisualLocator(config: enabledConfig(), client: client)
        _ = loc.predict(screenshot: Data([0x89, 0x50, 0x4E, 0x47]), description: "login button", viewportSize: (1280, 800))
        guard let body = client.lastBody,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return XCTFail("body not json")
        }
        XCTAssertEqual(obj["model"] as? String, "test-vlm")
        let messages = obj["messages"] as? [[String: Any]]
        let userMsg = messages?.first
        let content = userMsg?["content"] as? [[String: Any]]
        let textPart = content?.first { $0["type"] as? String == "text" }
        let promptText = textPart?["text"] as? String ?? ""
        XCTAssertTrue(promptText.contains("1280x800"), "prompt must name viewport size: \(promptText)")
        XCTAssertTrue(promptText.contains("login button"), "prompt must name description: \(promptText)")
        let imgPart = content?.first { $0["type"] as? String == "image_url" }
        let imgUrl = (imgPart?["image_url"] as? [String: Any])?["url"] as? String ?? ""
        XCTAssertTrue(imgUrl.hasPrefix("data:image/png;base64,"), "image must be a base64 data URI: \(imgUrl.prefix(30))")
    }

    // Config defaults: locator default-disabled, localhost fusion-mlx, sensible timeout.
    func testDefaultConfigDisabled() {
        let d = FBVisualLocatorConfig()
        XCTAssertFalse(d.enabled, "visual locator must default OFF (opt-in, needs VLM loaded)")
        XCTAssertEqual(d.endpoint, "http://127.0.0.1:11434")
        XCTAssertGreaterThan(d.timeoutMs, 0)
    }
}
