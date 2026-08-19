import XCTest
@testable import PokeTokenBar

// MARK: TradeDeepLink

final class TradeDeepLinkTests: XCTestCase {
    func testParsesValidLink() {
        let url = URL(string: "poketokenbar://trade?server=https%3A%2F%2Fx.example.com%3A3000&session=abc123")!
        let link = TradeDeepLink(url: url)
        XCTAssertEqual(link?.server, "https://x.example.com:3000")
        XCTAssertEqual(link?.sessionId, "abc123")
    }

    func testRejectsWrongScheme() {
        XCTAssertNil(TradeDeepLink(url: URL(string: "https://trade?server=x&session=y")!))
    }

    func testRejectsWrongHost() {
        XCTAssertNil(TradeDeepLink(url: URL(string: "poketokenbar://other?server=x&session=y")!))
    }

    func testRejectsMissingOrEmptyParams() {
        XCTAssertNil(TradeDeepLink(url: URL(string: "poketokenbar://trade?server=x")!))
        XCTAssertNil(TradeDeepLink(url: URL(string: "poketokenbar://trade?session=y")!))
        XCTAssertNil(TradeDeepLink(url: URL(string: "poketokenbar://trade?server=&session=y")!))
    }
}

// MARK: CompanionStore trade methods

/// For tests that need hatch() to actually succeed — returns a single non-evolving form.
private struct TradeStubProvider: PokeProviding {
    let value = EvoLine(baseID: 1, tree: EvoNode(speciesID: 1, children: []), rarity: .common, names: [:])
    func line(baseSpeciesID: Int) async throws -> EvoLine { value }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [BaseSpecies(id: value.baseID, captureRate: 255)] }
}

@MainActor
final class TradeCompanionStoreTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func store() -> CompanionStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trade-\(UUID().uuidString).json")
        return CompanionStore(provider: TradeStubProvider(), clock: { self.fixedNow }, fileURL: url, rng: SeededRNG(seed: 7))
    }

    private func mon(id: String = UUID().uuidString, baseID: Int = 1) -> MonState {
        MonState(id: id, baseID: baseID, pathIDs: [baseID], plannedPathIDs: [baseID], stageIndex: 0,
                usedAtStage: 0, rarity: .common, totalForms: 1)
    }

    func testBenchedPartyExcludesTrainingMon() async {
        let s = store()
        await s.hatch(baseID: 1)
        let training = try! XCTUnwrap(s.trainingMon)
        await s.hatch(baseID: 1)   // supersedes training slot; first mon stays in party, benched

        XCTAssertEqual(s.party.count, 2)
        XCTAssertEqual(s.benchedParty.map(\.id), [training.id])
    }

    func testRemoveFromPartyRefusesTrainingMonAndIsIdempotent() async {
        let s = store()
        await s.hatch(baseID: 1)
        let training = try! XCTUnwrap(s.trainingMon)

        XCTAssertFalse(s.removeFromParty(training.id), "the training mon is never removed (defensive)")
        XCTAssertEqual(s.party.count, 1)

        await s.hatch(baseID: 1)
        let benched = training

        XCTAssertTrue(s.removeFromParty(benched.id))
        XCTAssertEqual(s.party.count, 1)
        XCTAssertFalse(s.removeFromParty(benched.id), "an id that's already gone is a no-op — safe for repeated polling to reapply")
        XCTAssertEqual(s.party.count, 1)
    }

    func testAddTradedMonAppendsUnlocksDexAndIsIdempotent() {
        let s = store()
        let incoming = mon(baseID: 42)

        XCTAssertTrue(s.addTradedMon(incoming, from: "Misty"))
        XCTAssertEqual(s.party.count, 1)
        XCTAssertEqual(s.party.first?.id, incoming.id)
        XCTAssertNil(s.trainingMon, "a received mon joins benched — it doesn't hijack training in progress")
        XCTAssertEqual(s.state.dexUnlocked[42]?.rarity, .common, "the species a received mon has reached gets permanently unlocked")
        let logRow = s.state.dex.first { $0.monID == incoming.id }
        XCTAssertEqual(logRow?.source, .trade(from: "Misty"))

        XCTAssertFalse(s.addTradedMon(incoming, from: "Misty"), "reapplying the same id is a no-op — safe for repeated polling to reapply")
        XCTAssertEqual(s.party.count, 1)
    }

    /// The other side's MonState.acquiredVia can be an arbitrary value — it must not be trusted,
    /// and gets overwritten with the displayName confirmed by the session (spoofing guard).
    func testAddTradedMonOverwritesAcquiredViaWithSessionDisplayName() {
        let s = store()
        var incoming = mon()
        incoming.acquiredVia = .egg   // whatever the other side sent (a tampered example here) must be ignored

        XCTAssertTrue(s.addTradedMon(incoming, from: "Brock"))
        XCTAssertEqual(s.party.first?.acquiredVia, .trade(from: "Brock"))
    }

    /// A trade payload is just as untrusted an input as a save file — it must go through the same clamp.
    func testAddTradedMonSanitizesUntrustedValues() {
        let s = store()
        let poisoned = MonState(baseID: 1, pathIDs: [1], plannedPathIDs: [1],
                                stageIndex: Int.max, usedAtStage: Int.max, rarity: .common, totalForms: Int.max)

        XCTAssertTrue(s.addTradedMon(poisoned, from: "X"))
        let saved = try! XCTUnwrap(s.party.first)
        XCTAssertLessThanOrEqual(saved.totalForms, 12)
        XCTAssertLessThanOrEqual(saved.usedAtStage, SaveTransfer.maxTokenValue)
        XCTAssertEqual(saved.stageIndex, 0, "must not exceed the pathIDs range")
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 1, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }

    /// [Regression] Selecting an already-completed benched Pokémon from the PC (via setTrainingSlot)
    /// used to grant a bonus egg — loadCurrentLine's "usage crossed the threshold while the line was
    /// unloaded, catch up now" replay doesn't know the difference between a mon that's been training
    /// continuously and one that's simply always sat at its final threshold (a maxed-out bench mon,
    /// or a Pokémon received via trade already fully evolved). Selecting it must never re-trigger
    /// graduation.
    func testSelectingAnAlreadyCompletedBenchedMonDoesNotGrantANewEgg() async {
        let s = store()
        await s.hatch(baseID: 1)   // establishes a training mon so setTrainingSlot's guard is satisfiable

        var maxed = mon(baseID: 1)   // baseID 1 matches TradeStubProvider's single, childless node
        maxed.usedAtStage = PokemonBalance.graduationTotal(.common)   // already sitting at its final threshold
        XCTAssertTrue(s.addTradedMon(maxed, from: "Friend"))

        XCTAssertTrue(s.setTrainingSlot(to: maxed.id))
        let loaded = await waitUntil { s.currentLine != nil }
        XCTAssertTrue(loaded, "line load should complete")

        XCTAssertEqual(s.trainingMon?.id, maxed.id,
                       "the completed mon you selected must stay the training mon — it must not silently graduate and free the slot")
        XCTAssertNotNil(s.trainingMon, "must not have been bumped back to an egg")
        XCTAssertTrue(s.party.contains { $0.id == maxed.id })
    }
}

// MARK: TradeStore — network failure handling

/// Stubs every request with a fixed status/body — enough to test how TradeStore reacts to a
/// specific server response (e.g. a Vercel preview URL's 401 auth wall) without a real network call.
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class TradeStoreFailureTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func waitUntil(timeout: TimeInterval = 4, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func makeStores() -> (trade: TradeStore, offered: MonState) {
        let companionURL = FileManager.default.temporaryDirectory.appendingPathComponent("trade-store-\(UUID().uuidString).json")
        let companion = CompanionStore(provider: TradeStubProvider(), clock: { self.fixedNow }, fileURL: companionURL, rng: SeededRNG(seed: 7))
        let offered = MonState(baseID: 1, pathIDs: [1], plannedPathIDs: [1], stageIndex: 0, usedAtStage: 0, rarity: .common, totalForms: 1)
        _ = companion.addTradedMon(offered, from: "Friend")   // benched, so it's a legal offer candidate

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let online = OnlineStore(defaults: UserDefaults(suiteName: "TradeStoreFailureTests.\(UUID().uuidString)")!, session: session)
        online.serverURL = "https://mock.test"

        let reservationsURL = FileManager.default.temporaryDirectory.appendingPathComponent("trade-reservations-\(UUID().uuidString).json")
        let trade = TradeStore(companion: companion, online: online, fileURL: reservationsURL, session: session)
        return (trade, offered)
    }

    /// [Regression] A 401 (e.g. a Vercel preview URL's deployment-protection wall) used to land the
    /// user on a dead-end failure screen with only a raw `String(describing:)` error and no way back
    /// except a manual "Try again" tap. It must self-heal — surface an actionable message, then
    /// automatically return to the offer picker so the user can just fix the URL and retry.
    func testCreateTradeSurfacesAuthErrorAndAutoReturnsToIdle() async {
        StubURLProtocol.statusCode = 401
        StubURLProtocol.body = Data(#"{"error":{"code":"401","message":"Protected deployment"}}"#.utf8)
        let (trade, offered) = makeStores()

        await trade.createTrade(offering: offered)

        guard case .failed(.server(status: 401)) = trade.phase else {
            return XCTFail("expected a 401 server error, got \(trade.phase)")
        }
        XCTAssertFalse(trade.reservedMonIDs.contains(offered.id), "a failed create already releases the reservation synchronously")

        let returnedToIdle = await waitUntil { trade.phase == .idle }
        XCTAssertTrue(returnedToIdle, "a failed trade must not be a dead end requiring a manual tap")
    }
}

// MARK: SaveTransfer.sanitizedMon

final class SanitizedMonTests: XCTestCase {
    func testClampsExtremeValues() {
        let poisoned = MonState(baseID: 1, pathIDs: [1, 2], plannedPathIDs: [1, 2],
                                stageIndex: Int.max, usedAtStage: -5, rarity: .common, totalForms: Int.min)
        let cleaned = SaveTransfer.sanitizedMon(poisoned)
        XCTAssertEqual(cleaned.usedAtStage, 0, "negative clamps to 0")
        XCTAssertEqual(cleaned.totalForms, 1, "lower-bound clamp")
        XCTAssertEqual(cleaned.stageIndex, 1, "must not exceed pathIDs.count - 1")
    }
}
