import Foundation

/// PokeTokenBarOnline's trade session API — pure networking, no state (orchestration lives in
/// TradeStore). The server never interprets the `pokemon` field, only stores and forwards it
/// (opaque JSON), so we encode `MonState` as-is here too — no separate schema on the server side.
enum TradeClient {
    struct StatusResponse: Codable {
        let status: String   // "open" | "offered" | "completed"
        let counterpart: Counterpart?
        struct Counterpart: Codable {
            let displayName: String
            let pokemon: MonState
        }
    }

    enum TradeError: Error, Equatable {
        case invalidServerURL
        case network(String)
        case server(status: Int)
        case decoding
    }

    private struct OfferPayload: Encodable {
        let uuid: String
        let displayName: String
        let pokemon: MonState
    }
    private struct ConfirmPayload: Encodable { let uuid: String }
    private struct CreateResponse: Decodable { let sessionId: String }

    /// The save file (CompanionStore.save/load) uses the default encoding (epoch double), but this
    /// payload crosses a device boundary, so it follows the same convention as SaveTransfer
    /// (.iso8601) — a different persistence path, a different codec.
    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func request(_ url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        return req
    }

    private static func request(_ url: URL, method: String, body: some Encodable) throws(TradeError) -> URLRequest {
        var req = request(url, method: method)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let data = try? makeEncoder().encode(body) else { throw .decoding }
        req.httpBody = data
        return req
    }

    private static func send(_ req: URLRequest, session: URLSession) async throws(TradeError) -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw .network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw .network("no response") }
        guard (200..<300).contains(http.statusCode) else { throw .server(status: http.statusCode) }
        return data
    }

    static func create(serverURL: String, uuid: String, displayName: String, offering mon: MonState,
                        session: URLSession = .shared) async throws(TradeError) -> String {
        guard let url = OnlineStore.endpointURL(from: serverURL, path: "/trades") else { throw .invalidServerURL }
        let req = try request(url, method: "POST", body: OfferPayload(uuid: uuid, displayName: displayName, pokemon: mon))
        let data = try await send(req, session: session)
        guard let decoded = try? makeDecoder().decode(CreateResponse.self, from: data) else { throw .decoding }
        return decoded.sessionId
    }

    static func join(serverURL: String, sessionId: String, uuid: String, displayName: String, offering mon: MonState,
                      session: URLSession = .shared) async throws(TradeError) {
        guard let url = OnlineStore.endpointURL(from: serverURL, path: "/trades/\(sessionId)/join") else {
            throw .invalidServerURL
        }
        let req = try request(url, method: "POST", body: OfferPayload(uuid: uuid, displayName: displayName, pokemon: mon))
        _ = try await send(req, session: session)
    }

    static func status(serverURL: String, sessionId: String, uuid: String,
                        session: URLSession = .shared) async throws(TradeError) -> StatusResponse {
        guard let url = OnlineStore.endpointURL(from: serverURL, path: "/trades/\(sessionId)",
                                                queryItems: [URLQueryItem(name: "uuid", value: uuid)]) else {
            throw .invalidServerURL
        }
        let req = request(url, method: "GET")
        let data = try await send(req, session: session)
        guard let decoded = try? makeDecoder().decode(StatusResponse.self, from: data) else { throw .decoding }
        return decoded
    }

    static func confirm(serverURL: String, sessionId: String, uuid: String,
                         session: URLSession = .shared) async throws(TradeError) -> StatusResponse {
        guard let url = OnlineStore.endpointURL(from: serverURL, path: "/trades/\(sessionId)/confirm") else {
            throw .invalidServerURL
        }
        let req = try request(url, method: "POST", body: ConfirmPayload(uuid: uuid))
        let data = try await send(req, session: session)
        guard let decoded = try? makeDecoder().decode(StatusResponse.self, from: data) else { throw .decoding }
        return decoded
    }
}
