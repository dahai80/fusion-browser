import XCTest
@testable import FusionBrowser

// L-2/L-3/L-4 contract pin. The walker JS runs LIVE inside WKWebView and CANNOT be
// exercised under `swift test` (no main run loop -> evaluateJSSync semaphore deadlock).
// These tests pin the string-literal CONTRACT the fixes enforce, so a regression that
// re-introduces a bug (re-adding innerText to the fingerprint, dropping the resolveType
// stale check, re-registering a purged node in __fbMap) fails the suite loudly. This is
// the invariant-pinning pattern: when live code is untestable in-process, pin the
// invariant the fix relies on (Rule 9 — a test that passes for the wrong reason is worse
// than none; a missing-invariant pin is the next best thing to a behavior test). Live
// behavior stays verified via the release binary + Python smoke client, not here.
final class WalkerContractTests: XCTestCase {

    private func count(_ needle: String, in hay: String) -> Int {
        return hay.components(separatedBy: needle).count - 1
    }

    // L-3: the extract-time fingerprint must be STRUCTURAL only (tag|attrs|docPath).
    // The bug appended (el.innerText||"").trim().substring(0,24) — innerText is MUTABLE
    // across extracts (a button label flipping "Subscribe"->"Subscribed", or an input
    // value changing, mutates the fingerprint). resolveClick re-computes fp the same way
    // and compares, so a label change on a STILL-LIVE node made the click return
    // stale:true (false rejection of every click/type after a label/value change). Pin:
    // no `txt` local in the fingerprint path, and the structural return line is present.
    func testExtractFingerprintIsStructuralOnly() {
        let s = FBWalkerScript.extract
        XCTAssertFalse(s.contains("var txt="), "fingerprint must not carry a txt local (L-3 regression)")
        XCTAssertFalse(s.contains("+\"|\"+txt+\"|\""), "fingerprint must not append txt (L-3 regression)")
        XCTAssertTrue(s.contains("return tag+\"|\"+attrs.join(\",\")+\"|\"+docPath(el);"),
                      "fingerprint must be structural tag|attrs|docPath")
    }

    // L-3: resolveClick re-derives fp the SAME structural way (no txt) so a live node
    // matches the extract-time fingerprint. If txt crept back here, every live click
    // would go stale. Pin the structural fp line + the stale guard.
    func testResolveClickFingerprintMatchesExtractStructural() {
        let s = FBWalkerScript.resolveClick
        XCTAssertFalse(s.contains("var txt="), "resolveClick must not carry a txt local (L-3 regression)")
        XCTAssertFalse(s.contains("+\"|\"+txt+\"|\""), "resolveClick must not append txt (L-3 regression)")
        XCTAssertTrue(s.contains("var fp=tag+\"|\"+attrs.join(\",\")+\"|\"+parts.join(\"/\");"),
                      "resolveClick fp must be structural tag|attrs|docPath")
        XCTAssertTrue(s.contains("if(expectFp && fp!==expectFp) return JSON.stringify({ok:false, stale:true});"),
                      "resolveClick must guard fp mismatch with stale:true")
    }

    // L-2: resolveType previously declared+interpolated expectFp but NEVER compared it,
    // so typing raced blind into whatever element the recycled @eN WeakRef pointed at
    // (wrong-element typing with ok:true,stale:false after an SPA re-render reused a
    // tag/docPath). The fix mirrors resolveClick's fp stale check before el.focus().
    // Pin the guard + the structural fp re-derivation present.
    func testResolveTypeGuardsFingerprintBeforeFocus() {
        let s = FBWalkerScript.resolveType
        XCTAssertTrue(s.contains("if(expectFp && fp!==expectFp) return JSON.stringify({ok:false, stale:true});"),
                      "resolveType must compare fp before el.focus() (L-2 regression)")
        XCTAssertTrue(s.contains("var fp=tag+\"|\"+attrs.join(\",\")+\"|\"+parts.join(\"/\");"),
                      "resolveType must re-derive structural fp")
    }

    // L-4: a hidden/purged node must NOT be actionable. The old code still did
    // window.__fbMap.set(id, WeakRef(el)) for purged nodes (only blanking node.name), so
    // a click resolved the WeakRef and el.click() fired the hidden handler directly
    // (.click() bypasses hit-testing and invokes the handler regardless of visibility).
    // Fix: keep the node in `out` (markdown context) but register it in __fbMap ONLY in
    // the non-purged else branch. Pin: exactly ONE __fbMap.set registration site in
    // extract. A second site in the purge branch = the bug back.
    func testPurgedNodeNotRegisteredInFbMap() {
        let s = FBWalkerScript.extract
        let registrations = count("window.__fbMap.set(id, new WeakRef(el))", in: s)
        XCTAssertEqual(registrations, 1,
                       "exactly one __fbMap.set site (non-purged branch only); a 2nd in the purge branch = L-4 bug")
        XCTAssertTrue(s.contains("out.push(node)"), "purged node kept in out for markdown context")
    }
}
