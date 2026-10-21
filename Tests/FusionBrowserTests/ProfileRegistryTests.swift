import XCTest
@testable import FusionBrowser

// Issue #25: persistent-profile registry. Ownership is the auth-token hash (durable
// across reconnects / per-call-dial proxies); the registry maps profileId -> store id.
final class ProfileRegistryTests: XCTestCase {
    private var dir: URL!
    private var path: String!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fb-profile-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("profiles.json").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testResolveCreatesThenReusesSameStore() {
        let reg = FBProfileRegistry(path: path)
        let first = try! resolve(reg, "run-1", "hash-a")
        let again = try! resolve(reg, "run-1", "hash-a")
        XCTAssertEqual(first, again, "same owner reuses the same store id")
        XCTAssertEqual(reg.count(), 1)
    }

    func testCrossOwnerDenied() {
        let reg = FBProfileRegistry(path: path)
        _ = try! resolve(reg, "run-1", "hash-a")
        switch reg.resolve(profileId: "run-1", ownerTokenHash: "hash-b") {
        case .success:
            XCTFail("a different token must not adopt the profile")
        case .failure(let e):
            XCTAssertEqual(e.code, "profile_denied")
        }
    }

    func testDeleteCrossOwnerNotOwner() {
        let reg = FBProfileRegistry(path: path)
        _ = try! resolve(reg, "run-1", "hash-a")
        XCTAssertEqual(reg.delete(profileId: "run-1", ownerTokenHash: "hash-b", isSystemCaller: false)?.code, "not_owner")
        XCTAssertEqual(reg.count(), 1, "denied delete must keep the entry")
    }

    func testDeleteOwnerAndSystemCaller() {
        let reg = FBProfileRegistry(path: path)
        _ = try! resolve(reg, "run-1", "hash-a")
        XCTAssertNil(reg.delete(profileId: "run-1", ownerTokenHash: "hash-a", isSystemCaller: false))
        XCTAssertEqual(reg.count(), 0)
        _ = try! resolve(reg, "run-2", "hash-a")
        XCTAssertNil(reg.delete(profileId: "run-2", ownerTokenHash: "someone", isSystemCaller: true),
                     "system caller may delete")
        XCTAssertEqual(reg.count(), 0)
        XCTAssertNil(reg.delete(profileId: "nope", ownerTokenHash: "x", isSystemCaller: false),
                     "deleting an unknown id is a no-op success")
    }

    func testCorruptFileRebuildsFailSafe() throws {
        try "not json {{{".write(toFile: path, atomically: true, encoding: .utf8)
        let reg = FBProfileRegistry(path: path)
        XCTAssertEqual(reg.count(), 0, "corrupt registry reads as empty, never throws")
        let store = try resolve(reg, "run-1", "hash-a")
        XCTAssertFalse(store.isEmpty)
    }

    func testFileModeIs0600() throws {
        let reg = FBProfileRegistry(path: path)
        _ = try resolve(reg, "run-1", "hash-a")

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600, "registry holds profile ownership — owner-only read")
    }

    func testEntryRecordsOwnerAndCreatedAt() throws {
        let reg = FBProfileRegistry(path: path)
        _ = try resolve(reg, "run-1", "hash-a")
        let e = reg.entry(profileId: "run-1")
        XCTAssertEqual(e?.ownerTokenHash, "hash-a")
        XCTAssertNotNil(e?.createdAt)
        XCTAssertNotNil(e?.storeId)
    }

    private func resolve(_ reg: FBProfileRegistry, _ id: String, _ owner: String) throws -> String {
        switch reg.resolve(profileId: id, ownerTokenHash: owner) {
        case .success(let s): return s
        case .failure(let e): throw e
        }
    }
}
