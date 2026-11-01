import Foundation

struct SyncConflict: Error, Sendable {
    let current: SyncChange
}

private struct SyncFailureResponse: Decodable {
    var code: String
    var current: SyncChange?
}

protocol SyncTransport: Sendable {
    func send(_ operation: SyncOperation) async throws -> SyncChange
    func changes(after: Int, until: Int?) async throws -> SyncPage
    func acknowledge(cursor: Int) async throws
}

struct HTTPSyncTransport: SyncTransport {
    let serverURL: URL
    let accessToken: @Sendable () async throws -> String
    var session: URLSession = .shared

    func profileID() async throws -> String {
        struct Profile: Decodable { let id: String }
        let result: Profile = try await request("v1/profile")
        guard !result.id.isEmpty else { throw SyncError.invalidResponse }
        return result.id
    }

    func send(_ operation: SyncOperation) async throws -> SyncChange {
        try await request("v1/operations", method: "POST", body: SyncCodec.encoder().encode(operation))
    }

    func changes(after: Int, until: Int?) async throws -> SyncPage {
        var query = [URLQueryItem(name: "after", value: String(after)), URLQueryItem(name: "limit", value: "50")]
        if let until { query.append(URLQueryItem(name: "until", value: String(until))) }
        return try await request("v1/changes", query: query)
    }

    func acknowledge(cursor: Int) async throws {
        struct Ack: Codable { let cursor: Int }
        struct Result: Decodable { let ok: Bool }
        let _: Result = try await request("v1/ack", method: "POST", body: SyncCodec.encoder().encode(Ack(cursor: cursor)))
    }

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil,
                                       query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: serverURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw SyncError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SyncError.invalidResponse }
        if response.statusCode == 401 || response.statusCode == 403 { throw SyncError.authorizationRequired }
        if !(200..<300).contains(response.statusCode) {
            guard let failure = try? SyncCodec.decoder().decode(SyncFailureResponse.self, from: data) else { throw SyncError.invalidResponse }
            if let current = failure.current, response.statusCode == 409 || response.statusCode == 404 {
                throw SyncConflict(current: current)
            }
            throw SyncError.server(failure.code)
        }
        return try SyncCodec.decoder().decode(T.self, from: data)
    }
}
