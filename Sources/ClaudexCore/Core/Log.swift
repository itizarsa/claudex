import Foundation

/// A file the sign-in can be read back from. A menu bar app has no console, and the panel shows
/// one line of notice; when a login does not land, that line is rarely enough to say why.
///
/// Only the sign-in path writes here, so the file stays short enough to read by hand.
public enum Log {
    public static let url = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: "Library/Logs/claudex.log")

    private static let queue = DispatchQueue(label: "io.claudex.log")
    private static let maximumBytes = 512 * 1024

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public static func write(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Truncating beats rotating: the only reason to open this file is the run that just
            // happened, and a second file to look in is a second thing to forget.
            if let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > maximumBytes {
                try? manager.removeItem(at: url)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                try? Data(line.utf8).write(to: url)
                return
            }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}
