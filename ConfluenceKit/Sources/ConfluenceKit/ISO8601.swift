import Foundation

/// Both APIs return ISO-8601 timestamps, some with fractional seconds and some without.
enum ISO8601 {
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
    private static let lock = NSLock()

    static func date(from string: String) -> Date? {
        lock.withLock { withFraction.date(from: string) ?? plain.date(from: string) }
    }
}
