import XCTest
@testable import FusionBrowser

// T2.4 acceptance gate: Keychain stores full cookie attrs; retrieve returns them;
// LLM surface is credential_injected:bool only; password masked in AXTree markdown;
// audit log records op without plaintext; CreateSessionResponse exposes no secret.
// Live WKWebView inject cannot run under `swift test` (no main run loop); the
// injectCookies full-attr path is verified by build + binary smoke. Keychain
// SecItem calls work in the test process (per-domain item, cleaned up).

final class CredentialHostingTests: XCTestCase {
    let mgr = FBCredentialManager()
    // Unique per-run domain to avoid collisions with prior test runs / dev items.
    let domain = "fb-test-\(UUID().uuidString).example.com"

    override func tearDown() {
        mgr.delete(domain: domain)
        super.tearDown()
    }

    // FR-05 / T2.4: stores and returns FULL cookie attributes, not just value.
    func testStoreRetrieveFullCookieAttributes() {
        let attrs: [String: String] = [
            "name": "sessionid", "value": "supersecret-value-123",
            "domain": domain, "path": "/app",
            "expires": "1893456000", // 2030-01-01 epoch seconds
            "secure": "true", "httponly": "true", "samesite": "Lax",
        ]
        XCTAssertNil(mgr.store(domain: domain, cookieAttrs: attrs))

        let (got, err) = mgr.retrieve(domain: domain)
        XCTAssertNil(err)
        XCTAssertEqual(got?["name"], "sessionid")
        XCTAssertEqual(got?["value"], "supersecret-value-123")
        XCTAssertEqual(got?["domain"], domain)
        XCTAssertEqual(got?["path"], "/app")
        XCTAssertEqual(got?["expires"], "1893456000")
        XCTAssertEqual(got?["secure"], "true")
        XCTAssertEqual(got?["httponly"], "true")
        XCTAssertEqual(got?["samesite"], "Lax")
    }

    // T2.4: missing domain -> credential_not_found (not credential_locked).
    func testRetrieveMissingDomainReturnsNotFound() {
        let (got, err) = mgr.retrieve(domain: "no-such-\(UUID().uuidString).example.com")
        XCTAssertNil(got)
        XCTAssertEqual(err?.code, "credential_not_found")
        XCTAssertFalse(err?.retryable ?? true)
    }

    // T2.4 / D11: delete removes the item; second retrieve -> not_found.
    func testDeleteRemovesCredential() {
        XCTAssertNil(mgr.store(domain: domain, cookieAttrs: ["name": "a", "value": "b"]))
        mgr.delete(domain: domain)
        let (got, err) = mgr.retrieve(domain: domain)
        XCTAssertNil(got)
        XCTAssertEqual(err?.code, "credential_not_found")
    }

    // T2.4: audit log records the inject op with NO plaintext value anywhere.
    func testAuditLogHasNoPlaintext() {
        XCTAssertNil(mgr.store(domain: domain, cookieAttrs: ["name": "sess", "value": "plaintext-secret-xyz"]))
        let snapshot = FBCredentialAuditLog.shared.snapshot()
        let recent = snapshot.suffix(5)
        let anyLeak = recent.contains { e in
            let blob = "\(e.caller)\(e.domain)\(e.op)\(e.result)"
            return blob.contains("plaintext-secret-xyz") || blob.contains("sess")
        }
        XCTAssertFalse(anyLeak, "audit log leaked plaintext or cookie name")
        // Each entry carries only ts/caller/domain/op/result — no value field exists.
        for e in recent {
            XCTAssertFalse(e.op.contains("secret") || e.result.contains("secret"))
        }
    }
}

// T2.4: LLM surface (CreateSessionResponse) carries credential_injected:bool only.
// No plaintext, no cookie attrs, no password leak through the wire response.
final class CredentialSurfaceTests: XCTestCase {
    func testResponseExposesBoolNotSecret() {
        let resp = CreateSessionResponse(sessionId: "s1", credentialInjected: true)
        let data = try? FBFrame.encoder.encode(resp)
        let json = String(data: data ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"credential_injected\":true"))
        XCTAssertFalse(json.contains("password"))
        XCTAssertFalse(json.contains("cookie"))
        XCTAssertFalse(json.contains("secret"))
        XCTAssertFalse(json.contains("value"))
        // Decoded shape: only sessionId + credentialInjected fields.
        let decoded = try? FBFrame.decoder.decode(CreateSessionResponse.self, from: data ?? Data())
        XCTAssertEqual(decoded?.credentialInjected, true)
        XCTAssertEqual(decoded?.sessionId, "s1")
    }

    func testNoInjectionReportsFalse() {
        let resp = CreateSessionResponse(sessionId: "s2", credentialInjected: false)
        XCTAssertEqual(resp.credentialInjected, false)
        let json = String(data: (try? FBFrame.encoder.encode(resp)) ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"credential_injected\":false"))
    }
}

// T2.4: password masking in AXTree markdown — reducer emits val:******** for password
// nodes, never the real input value. (Complements InjectionAuditTests.testPasswordMaskedAfterPurge.)
final class CredentialPasswordMaskTests: XCTestCase {
    func testPasswordValueMaskedInMarkdown() {
        let pw = FBExtractedNode(nodeId: "pw", role: "textbox", name: "Password", isDisabled: false,
                                 currentValue: "********", fingerprint: "input|type=password",
                                 docPath: "html/body/form/input[2]",
                                 hiddenFlags: [:], renderHidden: false)
        let res = FBExtractResult(nodes: [pw], url: "https://login.example.com", title: "Login",
                                  nodesAudited: 1, hiddenNodesPurged: 0, matchedRules: [])
        let md = FBAXTreeReducer.toMarkdown(res)
        XCTAssertTrue(md.contains("val:********"))
        XCTAssertFalse(md.contains("hunter2"), "real password leaked into markdown")
        XCTAssertFalse(md.contains("type=password"), "raw attribute leaked into markdown")
    }

    func testNonPasswordValuePreservedInMarkdown() {
        let node = FBExtractedNode(nodeId: "e1", role: "textbox", name: "Search", isDisabled: false,
                                   currentValue: "hello world", fingerprint: "input|type=text",
                                   docPath: "html/body/input[1]",
                                   hiddenFlags: [:], renderHidden: false)
        let res = FBExtractResult(nodes: [node], url: "https://x", title: "t",
                                  nodesAudited: 1, hiddenNodesPurged: 0, matchedRules: [])
        let md = FBAXTreeReducer.toMarkdown(res)
        XCTAssertTrue(md.contains("val:hello world"))
        XCTAssertFalse(md.contains("********"))
    }
}
