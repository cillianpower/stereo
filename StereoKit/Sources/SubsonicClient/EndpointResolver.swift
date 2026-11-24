import Foundation

/// Picks the first configured base URL that answers, preferring earlier entries (LAN before remote).
///
/// Call `invalidate()` on network changes; the next request re-probes.
public actor EndpointResolver {
    public typealias Probe = @Sendable (URL) async -> Bool

    private let urls: [URL]
    private let probe: Probe
    private let grace: Duration
    private var resolved: URL?
    private var inFlight: Task<URL?, Never>?

    /// - Parameter grace: once a less-preferred URL answers, how long to keep waiting for a
    ///   more-preferred one. Away from home the LAN address never answers, so this caps the
    ///   delay at `grace` instead of a full connection timeout.
    public init(urls: [URL], grace: Duration = .milliseconds(750), probe: @escaping Probe) {
        self.urls = urls
        self.grace = grace
        self.probe = probe
    }

    public var current: URL? { resolved }

    public func invalidate() {
        resolved = nil
        inFlight?.cancel()
        inFlight = nil
    }

    public func resolve() async throws -> URL {
        if let resolved { return resolved }
        if let inFlight, let url = await inFlight.value {
            return url
        }
        let task = Task { [urls, probe, grace] in await Self.race(urls: urls, grace: grace, probe: probe) }
        inFlight = task
        let result = await task.value
        inFlight = nil
        guard let result else { throw SubsonicError.noReachableEndpoint }
        resolved = result
        return result
    }

    /// Probes all URLs concurrently and returns the most-preferred one that answers.
    ///
    /// The earliest URL wins as soon as it answers. A later URL wins once every earlier one has
    /// failed, or once `grace` has passed since it answered.
    static func race(urls: [URL], grace: Duration, probe: @escaping Probe) async -> URL? {
        guard !urls.isEmpty else { return nil }
        if urls.count == 1 { return await probe(urls[0]) ? urls[0] : nil }

        return await withTaskGroup(of: Int?.self) { group in
            for (i, url) in urls.enumerated() {
                group.addTask { await probe(url) ? i : -(i + 1) }   // success → i, failure → -(i+1)
            }
            var results = [Bool?](repeating: nil, count: urls.count)
            var graceExpired = false
            var graceStarted = false

            for await outcome in group {
                switch outcome {
                case nil: graceExpired = true
                case let i? where i >= 0: results[i] = true
                case let i?: results[-i - 1] = false
                }

                // Walk in preference order: take a success if everything before it failed,
                // or if the grace period has run out.
                for j in results.indices {
                    if results[j] == true {
                        group.cancelAll()
                        return urls[j]
                    }
                    if results[j] == nil {
                        if graceExpired, let k = results.firstIndex(where: { $0 == true }) {
                            group.cancelAll()
                            return urls[k]
                        }
                        break
                    }
                }

                if !graceStarted, results.contains(true) {
                    graceStarted = true
                    group.addTask { try? await Task.sleep(for: grace); return nil }
                }
            }
            return nil
        }
    }
}
