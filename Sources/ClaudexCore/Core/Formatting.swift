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
