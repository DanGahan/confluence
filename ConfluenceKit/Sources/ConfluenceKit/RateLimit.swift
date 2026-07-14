import Foundation

/// Transparent 429 retry policy shared by both API clients.
///
/// A 429 is honoured via `Retry-After` when the server provides it (seconds or an
/// HTTP-date), else exponential backoff (500ms → 1s → 2s) with ±20% jitter, capped
/// at three retries. If the final attempt is still a 429, the response is returned
/// as-is so callers can surface it as a rate-limited error to the UI.
///
/// Retries never touch other status codes — the caller keeps the existing 401/500
/// mapping. The helper only re-attempts 429.
enum RateLimit {
    /// Sleep hook — overridden in tests to skip real wall-clock delays.
    @TaskLocal static var sleep: @Sendable (UInt64) async throws -> Void = {
        try await Task.sleep(nanoseconds: $0)
    }
    /// Additional attempts after the initial request. Total request budget = retries + 1.
    @TaskLocal static var maxRetries: Int = 3
    /// Base delay for the exponential fallback (used only when no `Retry-After`).
    @TaskLocal static var baseDelayNanos: UInt64 = 500_000_000
}

extension URLSession {
    /// Like `data(for:)` but retries HTTP 429 per the shared rate-limit policy.
    func dataWithRateLimit(for request: URLRequest) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            let (data, response) = try await self.data(for: request)
            guard
                let http = response as? HTTPURLResponse,
                http.statusCode == 429,
                attempt < RateLimit.maxRetries
            else {
                return (data, response)
            }
            let delay = rateLimitBackoffNanos(
                attempt: attempt,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After")
            )
            try await RateLimit.sleep(delay)
            attempt += 1
        }
    }
}

/// Package-internal so tests can pin behaviour without instantiating a URLSession.
func rateLimitBackoffNanos(attempt: Int, retryAfter: String?) -> UInt64 {
    if let retryAfter, let seconds = parseRetryAfterSeconds(retryAfter) {
        return UInt64(max(0, min(seconds, 30)) * 1_000_000_000)
    }
    let base = Double(RateLimit.baseDelayNanos)
    let raw = base * pow(2.0, Double(attempt))
    let jitter = Double.random(in: 0.8...1.2)
    let capped = min(raw * jitter, 30_000_000_000)
    return UInt64(capped)
}

/// Retry-After is either delta-seconds or an HTTP-date; we accept the seconds form
/// (what both Bluesky and Mastodon send today).
private func parseRetryAfterSeconds(_ header: String) -> TimeInterval? {
    let trimmed = header.trimmingCharacters(in: .whitespaces)
    return TimeInterval(trimmed)
}

/// Whether an error thrown by a client should surface as a rate-limit state to the UI.
public func isRateLimitError(_ error: Error) -> Bool {
    if let e = error as? BlueskyError, e == .rateLimited { return true }
    if let e = error as? MastodonError, e == .rateLimited { return true }
    return false
}
