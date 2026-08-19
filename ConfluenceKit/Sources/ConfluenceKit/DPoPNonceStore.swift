import Foundation

/// Caches server-issued DPoP nonces per host (RFC 9449 §8/§9). The authorization and resource
/// servers hand out a `DPoP-Nonce`, expect it echoed on subsequent requests, and rotate it via
/// the response header. Reusing the cached nonce avoids a 401 round-trip on every call and — the
/// reason this exists — stops the intermittent failures the naive per-request dance produced under
/// concurrent requests (#105): the app fires several Bluesky calls at once and each was
/// independently racing the 401→retry handshake.
public actor DPoPNonceStore {
    public static let shared = DPoPNonceStore()
    private var nonces: [String: String] = [:] // host → most recent nonce

    public init() {}

    public func nonce(for host: String) -> String? { nonces[host] }

    /// Records the latest nonce from a response header (nil header = leave the cache as-is).
    public func store(_ nonce: String?, for host: String) {
        if let nonce, !nonce.isEmpty { nonces[host] = nonce }
    }
}
