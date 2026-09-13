import Foundation

public enum Formatting {
    private static let timeOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mma"
        formatter.amSymbol = "AM"
        formatter.pmSymbol = "PM"
        return formatter
    }()

    private static let dateAndTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mma"
        formatter.amSymbol = "AM"
        formatter.pmSymbol = "PM"
        return formatter
    }()

    /// "Resets Today 10:00PM" / "Resets Tomorrow 2:15AM" / "Resets Sep 15, 12:30AM".
    public static func resetLine(_ date: Date?) -> String {
        guard let date else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Resets Today \(timeOnly.string(from: date))" }
        if calendar.isDateInTomorrow(date) { return "Resets Tomorrow \(timeOnly.string(from: date))" }
        return "Resets \(dateAndTime.string(from: date))"
    }
}

/// Turns an error into something worth showing a person. Raw API bodies never reach the UI:
/// a truncated JSON blob tells the user nothing they can act on.
public enum ErrorPresenter {
    public static func message(_ raw: String) -> String {
        if raw.contains("HTTP 429") || raw.localizedCaseInsensitiveContains("rate limit") {
            return "Rate limited by the API. Retrying shortly."
        }
        if raw.contains("HTTP 401") || raw.contains("HTTP 403") {
            return "Signed out. Sign in again in the CLI."
        }
        if raw.range(of: #"HTTP 5\d\d"#, options: .regularExpression) != nil {
            return "The service is unavailable. Retrying shortly."
        }
        return raw
    }

    public static func message(_ error: Error) -> String {
        guard let claudexError = error as? ClaudexError else {
            return "Something went wrong: \(error.localizedDescription)"
        }

        switch claudexError {
        case .http(let status, _):
            switch status {
            case 401, 403: return "Signed out. Sign in again in the CLI."
            case 429: return "Rate limited by the API. Retrying shortly."
            case 500...599: return "The service is unavailable. Retrying shortly."
            default: return "Request failed (HTTP \(status))."
            }
        case .decoding:
            return "The usage API returned an unfamiliar response."
        case .notSignedIn(let kind):
            return "\(kind.displayName) CLI is not signed in."
        case .unsupportedAccount(let reason):
            return reason
        case .keychain:
            return "Could not read the Keychain."
        }
    }
}
