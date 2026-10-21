import XCTest
@testable import FusionBrowser

// Issue #25: the pure admission gate for profileId creates. Live create is webview-bound
// (ARCH-3), so the gate is the deterministic surface: cap + token attribution.
final class ProfileCreateTests: XCTestCase {
    func testGateNoProfileIdAlwaysAllowed() {
        XCTAssertNil(FBProfileGate.check(profileId: nil, caps: [], ownerKey: nil),
                     "today's non-persistent path is ungated (FR-04 unchanged)")
        XCTAssertNil(FBProfileGate.check(profileId: "", caps: [], ownerKey: "h"))
    }

    func testGateRequiresCap() {
        XCTAssertEqual(FBProfileGate.check(profileId: "run-1", caps: .default, ownerKey: "h")?.code,
                       "auth_denied", "profileId needs .persistentProfiles; .default lacks it")
    }

    func testGateRequiresOwnerKey() {
        XCTAssertEqual(FBProfileGate.check(profileId: "run-1",
                                           caps: [.persistentProfiles], ownerKey: nil)?.code,
                       "profile_denied", "a system caller has no token identity -> profile_denied")
    }

    func testGateAdmitsWithCapAndOwner() {
        XCTAssertNil(FBProfileGate.check(profileId: "run-1",
                                         caps: [.persistentProfiles], ownerKey: "hash"))
    }
}
