import Foundation

/// Decodes `T` but never throws: a malformed element yields `nil` instead of failing the decode.
/// Wrap array elements as `[FailableDecodable<T>]` so one bad item in a network payload doesn't
/// drop the whole page — Swift's default array decode is all-or-nothing, and we treat all network
/// input as hostile (CLAUDE.md). Recover the good values with `.compactMap { $0.value }`.
struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        // `FailableDecodable` itself always decodes successfully (consuming exactly this element's
        // slot in the container), so the array decode continues past a bad element.
        value = try? T(from: decoder)
    }
}
