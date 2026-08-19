import Foundation

/// `poketokenbar://trade?server=<url>&session=<id>` — kept as query parameters, not path segments.
/// The server value (a user-typed string that can contain `:`, e.g. `localhost:3000`) needs to sit
/// somewhere whose delimiter grammar doesn't collide with the value's own — a query value, not a
/// hand-parsed path segment.
struct TradeDeepLink: Equatable {
    let server: String
    let sessionId: String

    init?(url: URL) {
        guard url.scheme == "poketokenbar", url.host == "trade",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let server = items.first(where: { $0.name == "server" })?.value, !server.isEmpty,
              let sessionId = items.first(where: { $0.name == "session" })?.value, !sessionId.isEmpty
        else { return nil }
        self.server = server
        self.sessionId = sessionId
    }
}

/// Trade session orchestration — polling, applying completion, preventing a benched mon from being
/// offered in two trades at once (a client-local reservation). Doesn't touch CompanionState
/// (decision: the reservation list is a session concern, not a save-file concern) — persisted to
/// its own small file instead, so SaveTransfer's trust boundary and field classification stay
/// untouched.
@MainActor
@Observable
final class TradeStore {
    enum Phase: Equatable {
        case idle
        case waitingForJoin(sessionId: String, shareURL: URL?)
        case waitingForCounterpart(sessionId: String)
        case reviewingCounterpart(sessionId: String, counterpart: Offer)
        case completed(received: MonState, from: String)
        case failed(TradeClient.TradeError)
        case expired
    }
    struct Offer: Equatable {
        let displayName: String
        let pokemon: MonState
    }

    private(set) var phase: Phase = .idle
    private(set) var reservedMonIDs: Set<String> = []

    private let companion: CompanionStore
    private let online: OnlineStore
    private let fileURL: URL
    private let session: URLSession
    private var pollTask: Task<Void, Never>?
    /// The mon I offered in the trade currently in progress — on completion, this id gets removed
    /// and the counterpart's mon gets added.
    private var myOfferedMonID: String?

    init(companion: CompanionStore, online: OnlineStore, fileURL: URL? = nil, session: URLSession = .shared) {
        self.companion = companion
        self.online = online
        self.session = session
        self.fileURL = fileURL ?? Self.defaultURL()
        reservedMonIDs = Self.loadReservations(from: self.fileURL)
    }

    static func defaultURL() -> URL {
        let override = (ProcessInfo.processInfo.environment["PTB_STATE_DIR"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dir: URL
        if !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PokeTokenBar")
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("trade-reservations.json")
    }

    private static func loadReservations(from url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode(Set<String>.self, from: data) else { return [] }
        return ids
    }
    private func saveReservations() {
        guard let data = try? JSONEncoder().encode(reservedMonIDs) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: Starting — create / join

    func createTrade(offering mon: MonState) async {
        cancel()
        myOfferedMonID = mon.id
        reservedMonIDs.insert(mon.id)
        saveReservations()
        do {
            let sessionId = try await TradeClient.create(serverURL: online.serverURL, uuid: online.clientUUID,
                                                          displayName: online.displayName, offering: mon, session: session)
            let shareURL = OnlineStore.endpointURL(from: online.serverURL, path: "/t/\(sessionId)")
            phase = .waitingForJoin(sessionId: sessionId, shareURL: shareURL)
            startPolling(sessionId: sessionId)
        } catch {
            releaseReservation()
            fail(error)
        }
    }

    /// An invite that arrived via deep link — the UI reads this to show a "join this trade?" screen.
    /// If the server differs, the UI asks for one confirmation, then updates online.serverURL and
    /// calls joinTrade.
    private(set) var pendingInvite: TradeDeepLink?
    func handleIncomingLink(_ link: TradeDeepLink) {
        pendingInvite = link
    }

    func joinTrade(sessionId: String, server: String, offering mon: MonState) async {
        cancel()
        myOfferedMonID = mon.id
        reservedMonIDs.insert(mon.id)
        saveReservations()
        pendingInvite = nil
        do {
            try await TradeClient.join(serverURL: server, sessionId: sessionId, uuid: online.clientUUID,
                                       displayName: online.displayName, offering: mon, session: session)
            phase = .waitingForCounterpart(sessionId: sessionId)
            startPolling(sessionId: sessionId, server: server)
        } catch {
            releaseReservation()
            fail(error)
        }
    }

    // MARK: Polling

    private func startPolling(sessionId: String, server: String? = nil) {
        let serverURL = server ?? online.serverURL
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pollOnce(sessionId: sessionId, serverURL: serverURL)
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func pollOnce(sessionId: String, serverURL: String) async {
        do {
            let response = try await TradeClient.status(serverURL: serverURL, sessionId: sessionId,
                                                         uuid: online.clientUUID, session: session)
            switch response.status {
            case "offered":
                if let c = response.counterpart {
                    phase = .reviewingCounterpart(sessionId: sessionId, counterpart: Offer(displayName: c.displayName, pokemon: c.pokemon))
                } else {
                    phase = .waitingForCounterpart(sessionId: sessionId)
                }
            case "completed":
                if let c = response.counterpart, let mine = myOfferedMonID {
                    applyCompletion(Offer(displayName: c.displayName, pokemon: c.pokemon), myOfferedMonID: mine)
                }
                pollTask?.cancel()
            default:
                break   // "open" — still waiting for a join, nothing to do yet
            }
        } catch TradeClient.TradeError.server(status: 404) {
            phase = .expired
            releaseReservation()
            pollTask?.cancel()
        } catch TradeClient.TradeError.server(status: 401) {
            // A 401 is never transient — the server is unreachable as configured (wrong URL, or a
            // deployment behind an auth wall) and will keep rejecting every poll, so don't let this
            // spin the "waiting" spinner forever like a real network hiccup would.
            releaseReservation()
            fail(.server(status: 401))
        } catch {
            // A transient network failure retries on the next tick — don't overwrite phase with a
            // failure (keeps the spinner up).
        }
    }

    // MARK: Confirm / complete

    func confirm() async {
        guard case .reviewingCounterpart(let sessionId, _) = phase else { return }
        do {
            _ = try await TradeClient.confirm(serverURL: online.serverURL, sessionId: sessionId, uuid: online.clientUUID, session: session)
            // Applying completion is handled by the next polling tick (once the server returns
            // completed) — not applied optimistically here: if the other side hasn't confirmed yet,
            // the server still returns "offered", and if I'd already removed my mon by then, there'd
            // be no way to undo it if the other side cancels or the trade expires.
        } catch {
            fail(error)
        }
    }

    /// Puts up the failure screen, then automatically returns to the offer picker (same as tapping
    /// "Try again") after a beat — a stuck dead-end screen just makes someone quit and re-open the
    /// popover, which does the same reset anyway.
    private func fail(_ error: TradeClient.TradeError) {
        pollTask?.cancel()
        pollTask = nil
        phase = .failed(error)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, case .failed = self.phase else { return }
            self.cancel()
        }
    }

    /// Applies a completed trade — idempotent (both removeFromParty/addTradedMon are a no-op for
    /// an id already handled). Safe for a late-arriving poll to call this again.
    private func applyCompletion(_ counterpart: Offer, myOfferedMonID: String) {
        companion.removeFromParty(myOfferedMonID)
        companion.addTradedMon(counterpart.pokemon, from: counterpart.displayName)
        releaseReservation()
        phase = .completed(received: counterpart.pokemon, from: counterpart.displayName)
    }

    private func releaseReservation() {
        if let id = myOfferedMonID { reservedMonIDs.remove(id) }
        myOfferedMonID = nil
        saveReservations()
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        if case .completed = phase {} else { releaseReservation() }
        phase = .idle
    }
}
