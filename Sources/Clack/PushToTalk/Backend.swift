import Foundation

// Thin client for Clack-Worker — the signaling backend that mints LiveKit
// tokens, stores ephemeral PushToTalk tokens, and fans out `pushtotalk` APNs
// when someone starts transmitting. See ../Clack-Worker for the API.
//
// The base URL is the deployed Worker. Override at launch with a `CLACK_BACKEND`
// Info.plist string (handy for pointing TestFlight at a staging deploy) or edit
// the fallback below after `wrangler deploy`.
struct Backend {
    let baseURL: URL

    init() {
        let fromPlist = Bundle.main.object(forInfoDictionaryKey: "CLACK_BACKEND") as? String
        // Deployed Clack-Worker. Override with a CLACK_BACKEND Info.plist string
        // to point a build at a staging deploy.
        let fallback = "https://clack-worker.snow-whitehouse.workers.dev"
        baseURL = URL(string: fromPlist ?? fallback)!
    }

    struct TokenResponse: Decodable {
        let url: String       // wss://… LiveKit host
        let token: String     // LiveKit access token
        let expiresAt: Double
    }

    /// Join `channel` and get a LiveKit access token for the room.
    func token(channel: String, identity: String, name: String) async throws -> TokenResponse {
        try await post("/v1/token", ["channel": channel, "identity": identity, "name": name])
    }

    /// Register/refresh this device's ephemeral PushToTalk token for `channel`.
    func registerPushToken(channel: String, identity: String, name: String, token: String) async throws {
        let _: OK = try await post(
            "/v1/push-token",
            ["channel": channel, "identity": identity, "name": name, "token": token])
    }

    /// Tell the backend to wake other members — fans out `pushtotalk` APNs.
    func transmitStart(channel: String, identity: String, name: String) async throws {
        let _: OK = try await post(
            "/v1/transmit/start", ["channel": channel, "identity": identity, "name": name])
    }

    func transmitStop(channel: String, identity: String, name: String) async throws {
        let _: OK = try await post(
            "/v1/transmit/stop", ["channel": channel, "identity": identity, "name": name])
    }

    func leave(channel: String, identity: String) async throws {
        let _: OK = try await post("/v1/leave", ["channel": channel, "identity": identity])
    }

    // MARK: - Messages (text + voice transcripts)

    /// Persist a channel message for history.
    func postMessage(channel: String, identity: String, _ m: TranscriptMessage) async throws {
        let _: OK = try await postJSON("/v1/message", [
            "id": m.id.uuidString, "channel": channel, "identity": identity,
            "name": m.speaker, "kind": m.kind.rawValue, "lang": m.lang,
            "text": m.text, "ts": m.ts * 1000,
        ])
    }

    /// Fetch the channel's message history (≤24h).
    func fetchMessages(channel: String) async throws -> [Transmission] {
        let response: MessagesResponse = try await get("/v1/messages", query: ["channel": channel])
        return response.transmissions
    }

    // MARK: - Location (lone-worker tracking)

    /// Push one location breadcrumb for the channel.
    func postLocation(channel: String, identity: String, name: String,
                      lat: Double, lon: Double, accuracy: Double?) async throws {
        var body: [String: Any] = [
            "channel": channel, "identity": identity, "name": name,
            "lat": lat, "lon": lon,
        ]
        if let accuracy { body["accuracy"] = accuracy }
        let _: OK = try await postJSON("/v1/location", body)
    }

    /// Each member's latest position + 8h trail for the channel.
    func fetchLocations(channel: String) async throws -> LocationsResponse {
        try await get("/v1/locations", query: ["channel": channel])
    }

    // MARK: - Plumbing

    private struct OK: Decodable {}

    private func postJSON<T: Decodable>(_ path: String, _ body: [String: Any]) async throws -> T {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private func get<T: Decodable>(_ path: String, query: [String: String]) async throws -> T {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return try await send(URLRequest(url: comps.url!))
    }

    private func post<T: Decodable>(_ path: String, _ body: [String: String]) async throws -> T {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw BackendError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        if T.self == OK.self { return OK() as! T }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

enum BackendError: Error {
    case http(Int, String)
}
