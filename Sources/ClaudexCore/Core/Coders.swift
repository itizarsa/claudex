import Foundation

/// Timestamps may or may not carry fractional seconds, so both forms are accepted.
enum ISO8601 {
    private static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from text: String) -> Date? {
        withFractional.date(from: text) ?? plain.date(from: text)
    }

    static func string(from date: Date) -> String {
        withFractional.string(from: date)
    }
}

/// Lenient reader over decoded JSON. CLIProxyAPI's management output is not a documented contract,
/// so every lookup is allowed to miss and the caller decides what a miss means.
struct JSONView {
    let raw: Any?

    init(_ raw: Any?) { self.raw = raw }

    subscript(key: String) -> JSONView {
        JSONView((raw as? [String: Any])?[key])
    }

    var array: [JSONView] { ((raw as? [Any]) ?? []).map(JSONView.init) }
    var string: String? { raw as? String }
    var double: Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let text = raw as? String { return Double(text) }
        return nil
    }
    var int: Int? { double.map(Int.init) }
    var bool: Bool? { raw as? Bool }
    var exists: Bool { raw != nil && !(raw is NSNull) }

    /// ISO 8601 string or unix seconds, whichever the endpoint happens to use.
    var date: Date? {
        if let text = string { return ISO8601.date(from: text) }
        if let seconds = double { return Date(timeIntervalSince1970: seconds) }
        return nil
    }

    static func parse(_ data: Data) throws -> JSONView {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSONView(object)
    }
}
