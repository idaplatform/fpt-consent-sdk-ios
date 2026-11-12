import XCTest
@testable import ConsentCmp

private final class AppearanceMemoryStorage: StoragePort {
    private var values: [String: String] = [:]
    private(set) var writes = 0
    func get(_ key: String) -> String? { values[key] }
    func set(_ key: String, _ value: String) { values[key] = value; writes += 1 }
    func remove(_ key: String) { values.removeValue(forKey: key) }
}

private final class AppearanceHttp: HttpPort {
    private let lock = NSLock()
    private var count = 0
    var fails = false
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    var revision = "remote"
    var includesAppearance = true
    var primaryColor = "#673AB7"
    private(set) var paths: [String] = []
    private func response(_ request: HttpRequest) throws -> HttpResponse {
        lock.lock(); defer { lock.unlock() }; count += 1
        paths.append(URL(string: request.url)?.path ?? "")
        guard URL(string: request.url)?.path == "/api/v1/cmp/consent/config" else {
            return HttpResponse(status: 404, body: "{}")
        }
        if fails { throw ConsentError(message: "offline") }
        var data: [String: Any] = ["code": "cp-test", "status": "active", "fields": [], "config": ["items": []]]
        if includesAppearance {
            data["appearance"] = ["schemaVersion": 1, "revision": revision, "theme": ["colors": ["primary": primaryColor]], "typography": ["family": "system"]] as [String: Any]
        }
        let body = try JSONSerialization.data(withJSONObject: ["data": data])
        return HttpResponse(status: 200, body: String(decoding: body, as: UTF8.self))
    }
    func send(_ request: HttpRequest) async throws -> HttpResponse { try response(request) }
}

private actor PausedAppearanceHttp: HttpPort {
    private(set) var started = false
    private var completion: CheckedContinuation<HttpResponse, Error>?
    func send(_ request: HttpRequest) async throws -> HttpResponse {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            started = true
        }
    }
    func finish(_ raw: String) {
        completion?.resume(returning: HttpResponse(status: 200, body: raw))
        completion = nil
    }
}

final class ConsentAppearanceTests: XCTestCase {
    func testPersistedAppearanceAvoidsNetworkAfterRepositoryRestart() async {
        let http = AppearanceHttp(), storage = AppearanceMemoryStorage()
        let options = ConsentOptions(codeConfig: "cp-test")
        let first = AppearanceRepository(options: options, http: http, storage: storage)
        let loaded = await first.get()
        XCTAssertEqual(loaded.revision, "remote")
        let reopened = AppearanceRepository(options: options, http: http, storage: storage)
        let cached = await reopened.get()
        XCTAssertEqual(cached.revision, "remote")
        XCTAssertEqual(http.calls, 1)
    }
    func testOfflineUsesDefaultOnceAndRetriesNextSession() async {
        let http = AppearanceHttp(), storage = AppearanceMemoryStorage()
        http.fails = true
        let options = ConsentOptions(codeConfig: "cp-test")
        let first = AppearanceRepository(options: options, http: http, storage: storage)
        let fallback = await first.get()
        _ = await first.get()
        XCTAssertEqual(fallback.revision, "default"); XCTAssertEqual(http.calls, 1)
        http.fails = false
        let second = AppearanceRepository(options: options, http: http, storage: storage)
        let retried = await second.get()
        XCTAssertEqual(retried.revision, "remote"); XCTAssertEqual(http.calls, 2)
    }
    func testConcurrentReadsShareRequestAndRefreshFailureKeepsCache() async {
        let http = AppearanceHttp()
        let repo = AppearanceRepository(options: ConsentOptions(codeConfig: "cp-test"), http: http, storage: AppearanceMemoryStorage())
        async let a = repo.get()
        async let b = repo.get()
        _ = await (a, b)
        XCTAssertEqual(http.calls, 1)
        http.fails = true
        let kept = await repo.refresh()
        XCTAssertEqual(kept.revision, "remote")
    }
    func testClearAndCollectionPointIsolation() async {
        let http = AppearanceHttp(), storage = AppearanceMemoryStorage()
        let first = AppearanceRepository(options: ConsentOptions(codeConfig: "one"), http: http, storage: storage)
        let second = AppearanceRepository(options: ConsentOptions(codeConfig: "two"), http: http, storage: storage)
        _ = await first.get(); _ = await second.get()
        XCTAssertEqual(http.calls, 2)
        await first.clear(); _ = await first.get()
        XCTAssertEqual(http.calls, 3)
    }
    func testFormUsesOneConfigRequestAndAutomaticallyUpdatesAppearance() async throws {
        let http = AppearanceHttp()
        let cmp = ConsentCmp(options: ConsentOptions(codeConfig: "cp-test"), http: http,
                             storage: AppearanceMemoryStorage(), appearanceStorage: AppearanceMemoryStorage())
        _ = try await cmp.fetchConfig()
        XCTAssertEqual(cmp.appearance.revision, "remote"); XCTAssertEqual(http.calls, 1)
        http.revision = "changed"
        _ = try await cmp.fetchConfig()
        XCTAssertEqual(cmp.appearance.revision, "changed"); XCTAssertEqual(http.calls, 2)
        _ = await cmp.refreshAppearance()
        XCTAssertEqual(cmp.appearance.revision, "changed"); XCTAssertEqual(http.calls, 3)
        _ = await cmp.getAppearance()
        XCTAssertEqual(http.calls, 3)
        XCTAssertTrue(http.paths.allSatisfy { $0 == "/api/v1/cmp/consent/config" })
    }
    func testCachedContentRestoresAppearanceWithoutNetwork() async throws {
        let http = AppearanceHttp()
        let cmp = ConsentCmp(options: ConsentOptions(codeConfig: "cp-test"), http: http,
                             storage: AppearanceMemoryStorage(), appearanceStorage: AppearanceMemoryStorage())
        _ = try await cmp.fetchConfig()
        await cmp.clearAppearanceCache()
        _ = try await cmp.fetchConfig(preferCache: true)
        XCTAssertEqual(cmp.appearance.revision, "remote"); XCTAssertEqual(http.calls, 1)
    }
    func testMissingAppearanceDoesNotFailContent() async throws {
        let http = AppearanceHttp(); http.includesAppearance = false
        let cmp = ConsentCmp(options: ConsentOptions(codeConfig: "cp-test"), http: http,
                             storage: AppearanceMemoryStorage(), appearanceStorage: AppearanceMemoryStorage())
        _ = try await cmp.fetchConfig()
        XCTAssertEqual(cmp.appearance.revision, "default"); XCTAssertEqual(http.calls, 1)
    }
    func testAppearanceLimitAppliesToTokensRatherThanWholeConfig() throws {
        let data: [String: Any] = ["description": String(repeating: "x", count: 40000),
                                  "appearance": ["schemaVersion": 1, "revision": "large-config", "theme": [:], "typography": [:]]]
        let raw = try JSONSerialization.data(withJSONObject: ["data": data])
        XCTAssertEqual(try ConsentAppearance.fromConfig(String(decoding: raw, as: UTF8.self)).revision, "large-config")
        XCTAssertThrowsError(try ConsentAppearance.fromConfig("{\"data\":{\"appearance\":{\"schemaVersion\":99}}}"))
    }

    func testMissingAppearanceKeepsCacheAndLaterValidResponseRecovers() async throws {
        let http = AppearanceHttp(); http.includesAppearance = false
        let cmp = ConsentCmp(options: ConsentOptions(codeConfig: "cp-test"), http: http,
                             storage: AppearanceMemoryStorage(), appearanceStorage: AppearanceMemoryStorage())
        _ = try await cmp.fetchConfig()
        XCTAssertEqual(cmp.appearance.revision, "default")
        http.includesAppearance = true
        _ = try await cmp.fetchConfig()
        XCTAssertEqual(cmp.appearance.revision, "remote")
        http.includesAppearance = false
        _ = try await cmp.fetchConfig()
        XCTAssertEqual(cmp.appearance.revision, "remote"); XCTAssertEqual(http.calls, 3)
    }
    func testChangedTokensWithSameRevisionAreApplied() async throws {
        let http = AppearanceHttp()
        let cmp = ConsentCmp(options: ConsentOptions(codeConfig: "cp-test"), http: http,
                             storage: AppearanceMemoryStorage(), appearanceStorage: AppearanceMemoryStorage())
        _ = try await cmp.fetchConfig()
        http.primaryColor = "#D84315"
        _ = try await cmp.fetchConfig()
        XCTAssertEqual(cmp.appearance.color("primary"), 0xD84315)
        XCTAssertEqual(http.calls, 2)
    }
    func testOlderCachedContentDoesNotDowngradeANewerTheme() async throws {
        let http = AppearanceHttp()
        let cmp = ConsentCmp(options: ConsentOptions(codeConfig: "cp-test"), http: http,
                             storage: AppearanceMemoryStorage(), appearanceStorage: AppearanceMemoryStorage())
        _ = try await cmp.fetchConfig()
        http.revision = "newer"
        _ = await cmp.refreshAppearance()
        _ = try await cmp.fetchConfig(preferCache: true)
        XCTAssertEqual(cmp.appearance.revision, "newer"); XCTAssertEqual(http.calls, 2)
    }
    func testReorderedUnchangedAppearanceDoesNotRewriteCache() async {
        let storage = AppearanceMemoryStorage(), http = AppearanceHttp()
        let repo = AppearanceRepository(options: ConsentOptions(codeConfig: "same"), http: http, storage: storage)
        let first = "{\"data\":{\"appearance\":{\"schemaVersion\":1,\"revision\":\"stable\",\"theme\":{},\"typography\":{\"family\":\"serif\"}}}}"
        let reordered = "{\"data\":{\"appearance\":{\"typography\":{\"family\":\"serif\"},\"theme\":{},\"revision\":\"stable\",\"schemaVersion\":1}}}"
        _ = await repo.fromConfig(first)
        _ = await repo.fromConfig(reordered)
        XCTAssertEqual(storage.writes, 1); XCTAssertEqual(http.calls, 0)
        let invalid = await repo.fromConfig("{\"data\":{\"appearance\":{\"schemaVersion\":99}}}")
        XCTAssertEqual(invalid.revision, "stable"); XCTAssertEqual(storage.writes, 1)
    }
    func testNewConfigIsNotDiscardedBehindAnInFlightAppearanceRequest() async {
        let http = PausedAppearanceHttp()
        let repo = AppearanceRepository(options: ConsentOptions(codeConfig: "pending"), http: http, storage: AppearanceMemoryStorage())
        let old = "{\"data\":{\"code\":\"pending\",\"appearance\":{\"schemaVersion\":1,\"revision\":\"old\",\"theme\":{},\"typography\":{}},\"status\":\"active\",\"fields\":[],\"config\":{\"items\":[]}}}"
        let fresh = "{\"data\":{\"appearance\":{\"schemaVersion\":1,\"revision\":\"fresh\",\"theme\":{},\"typography\":{}}}}"
        let first = Task { await repo.get() }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let started = await http.started
            if started { break }
            await Task.yield()
        }
        let didStart = await http.started
        guard didStart else {
            first.cancel(); await http.finish(old)
            XCTFail("Appearance request did not start"); return
        }
        let updated = Task { await repo.fromConfig(fresh) }
        await http.finish(old)
        let original = await first.value
        let loaded = await updated.value
        XCTAssertEqual(original.revision, "old")
        let cached = await repo.get()
        XCTAssertEqual(loaded.revision, "fresh"); XCTAssertEqual(cached.revision, "fresh")
    }

}
