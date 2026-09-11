import Foundation

enum HTTP {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    struct Response {
        let status: Int
        let data: Data
        var json: JSONView { (try? JSONView.parse(data)) ?? JSONView(nil) }
    }

    static func get(_ url: URL, headers: [String: String]) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        apply(headers, to: &request)
        return try await send(request)
    }

    static func postJSON(_ url: URL, body: [String: Any], headers: [String: String] = [:]) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        var merged = headers
        merged["Content-Type"] = "application/json"
        apply(merged, to: &request)
        return try await send(request)
    }

    private static func apply(_ headers: [String: String], to request: inout URLRequest) {
        request.setValue(Endpoints.userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    private static func send(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ClaudexError.http(status, String(decoding: data, as: UTF8.self))
        }
        return Response(status: status, data: data)
    }
}

extension ClaudexError {
    var httpStatus: Int? {
        if case .http(let code, _) = self { return code }
        return nil
    }

    var isUnauthorized: Bool { httpStatus == 401 || httpStatus == 403 }
    var isRetryable: Bool {
        guard let status = httpStatus else { return true }
        return status == 429 || status >= 500
    }
}
