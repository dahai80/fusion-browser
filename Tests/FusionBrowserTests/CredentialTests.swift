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

    // E-14: per-cookie delete removes ONLY the named cookie, not the whole domain.
    // Two cookies share a domain (different name|path — F-10 keys); deleting one must
    // leave the other intact. This is the session-logout contract: session A's logout
    // (which injected only cookie A) must not clobber session B's cookie B. A bulk
    // delete(domain:) would remove both; the per-cookie overload removes one.
    func testPerCookieDeleteLeavesOtherCookieIntact() {
        let cookieA: [String: String] = ["name": "sessA", "value": "valA", "domain": domain, "path": "/"]
        let cookieB: [String: String] = ["name": "csrfB", "value": "valB", "domain": domain, "path": "/admin"]
        XCTAssertNil(mgr.store(domain: domain, cookieAttrs: cookieA))
        XCTAssertNil(mgr.store(domain: domain, cookieAttrs: cookieB))

        // Both present.
        let (all0, _) = mgr.retrieveAll(domain: domain)
        XCTAssertEqual(all0.count, 2, "both cookies stored under shared domain")

        // Delete ONLY cookieA by attrs.
        XCTAssertTrue(mgr.delete(domain: domain, cookieAttrs: cookieA), "per-cookie delete reports ok")

        // cookieB survives.
        let (all1, err1) = mgr.retrieveAll(domain: domain)
        XCTAssertNil(err1)
        XCTAssertEqual(all1.count, 1, "other cookie survived the per-cookie delete")
        XCTAssertEqual(all1.first?["name"], "csrfB")

        // Delete cookieB by attrs.
        XCTAssertTrue(mgr.delete(domain: domain, cookieAttrs: cookieB))

        // Both gone — retrieveAll returns an empty array + credential_not_found.
        let (all2, err2) = mgr.retrieveAll(domain: domain)
        XCTAssertTrue(all2.isEmpty)
        XCTAssertEqual(err2?.code, "credential_not_found")
    }

    // E-14: per-cookie delete with a missing name is a safe no-op (returns false), never
    // a silent bulk delete.
    func testPerCookieDeleteMissingNameIsNoOp() {
        XCTAssertNil(mgr.store(domain: domain, cookieAttrs: ["name": "keep", "value": "v"]))
        XCTAssertFalse(mgr.delete(domain: domain, cookieAttrs: ["path": "/"]), "missing name does not delete")
        let (all, _) = mgr.retrieveAll(domain: domain)
        XCTAssertEqual(all.count, 1, "cookie survived the missing-name no-op")
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

// Issue #25: the cookie SHAPE built for injection, testable without a live WKWebView.
// Root cause this pins: passing `.secure: false` as a Bool made every injected cookie
// Secure=TRUE (HTTPCookie treats the key's presence as true), so an http:// page never
// received it and document.cookie hid it. The helper now omits the key unless secure.
final class CookieInjectionTests: XCTestCase {
    private func attrs(_ extra: [String: String]) -> [String: String] {
        var a = ["name": "session", "value": "ok", "domain": "localhost", "path": "/"]
        a.merge(extra) { _, new in new }
        return a
    }

    func testInsecureCookieIsNotMarkedSecure() {
        let cookie = FBWebView.cookieFromAttrs(attrs(["secure": "false"]), domain: "localhost")
        XCTAssertNotNil(cookie)
        XCTAssertEqual(cookie?.isSecure, false, "secure=false must not become Secure")
        XCTAssertEqual(cookie?.domain, "localhost")
        XCTAssertEqual(cookie?.path, "/")
        XCTAssertEqual(cookie?.name, "session")
        XCTAssertEqual(cookie?.value, "ok")
    }

    func testSecureCookieKeepsSecure() {
        let cookie = FBWebView.cookieFromAttrs(attrs(["secure": "true"]), domain: "localhost")
        XCTAssertEqual(cookie?.isSecure, true)
    }

    func testSameSiteIsThreadedThrough() {
        // CFNetwork normalizes the spelling ("lax"), so assert carried-or-not, not casing.
        let key = HTTPCookiePropertyKey(rawValue: "SameSite")
        XCTAssertEqual(FBWebView.cookieFromAttrs(attrs(["samesite": "lax"]), domain: "d")?
                        .properties?[key] as? String, "lax")
        XCTAssertEqual(FBWebView.cookieFromAttrs(attrs(["samesite": "strict"]), domain: "d")?
                        .properties?[key] as? String, "strict")
        XCTAssertNil(FBWebView.cookieFromAttrs(attrs(["samesite": ""]), domain: "d")?
                        .properties?[key])
    }

    func testExpiresAndHttpOnlyThreadedThrough() {
        // CFNetwork clamps Expires to ~400 days, so pin a date inside that window.
        let when = Date().addingTimeInterval(30 * 86400)
        let cookie = FBWebView.cookieFromAttrs(
            attrs(["expires": String(Int64(when.timeIntervalSince1970)), "httponly": "true"]),
            domain: "localhost")
        XCTAssertEqual(cookie?.isSessionOnly, false)
        let delta = abs((cookie?.expiresDate?.timeIntervalSince1970 ?? 0) - when.timeIntervalSince1970)
        XCTAssertLessThan(delta, 2.0)
        XCTAssertEqual(cookie?.isHTTPOnly, true)
    }

    func testMissingNameOrValueRejected() {
        XCTAssertNil(FBWebView.cookieFromAttrs(["value": "v"], domain: "d"))
        XCTAssertNil(FBWebView.cookieFromAttrs(["name": "n"], domain: "d"))
    }
}
