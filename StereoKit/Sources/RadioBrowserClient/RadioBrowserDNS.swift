import Foundation

/// Implements the API's recommended mirror discovery: resolve every A/AAAA record of the pool name,
/// then reverse-resolve each address to its mirror hostname (needed for TLS).
enum RadioBrowserDNS {
    static func mirrorHosts(pool: String) async -> [String] {
        await Task.detached(priority: .utility) { () -> [String] in
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(pool, "443", &hints, &result) == 0, let first = result else { return [] }
            defer { freeaddrinfo(result) }

            var names = Set<String>()
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let info = cursor {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0 {
                    let name = String(cString: host)
                    if name.hasSuffix("radio-browser.info") { names.insert(name) }
                }
                cursor = info.pointee.ai_next
            }
            return Array(names)
        }.value
    }
}
