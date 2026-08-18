import Foundation
import Observation

/// Opt-in connection to a self-hosted PokeTokenBarOnline server (trading, later battles).
/// No server configured = fully offline, unchanged app behavior — this store only exists to
/// remember a URL and ping it; it does not gate anything elsewhere in the app yet.
@MainActor
@Observable
final class OnlineStore {
    enum PingResult: Equatable {
        case idle
        case checking
        case success
        case failure(String)
    }

    var serverURL: String {
        didSet { defaults.set(serverURL, forKey: "onlineServerURL") }
    }
    var displayName: String {
        didSet { defaults.set(displayName, forKey: "onlineDisplayName") }
    }
    private(set) var pingResult: PingResult = .idle

    private let defaults: UserDefaults
    private let session: URLSession

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        serverURL = defaults.string(forKey: "onlineServerURL") ?? ""
        displayName = defaults.string(forKey: "onlineDisplayName") ?? ""
    }

    func ping() async {
        guard let url = Self.healthURL(from: serverURL) else {
            pingResult = .failure("Invalid URL")
            return
        }
        pingResult = .checking
        do {
            let (_, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                pingResult = .failure("Unexpected response")
                return
            }
            pingResult = .success
        } catch {
            pingResult = .failure(error.localizedDescription)
        }
    }

    /// Normalizes a user-entered host into the server's `/health` endpoint. Users type a bare
    /// domain (`trade.example.com`), not a full URL — default to `https://` when no scheme is
    /// given, same mental model as pointing a game client at a server address.
    nonisolated static func healthURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
              let host = components.host, !host.isEmpty else { return nil }
        components.path = "/health"
        return components.url
    }
}
