import Foundation

/// Reads the running app's own entitlements from its executable.
///
/// Why: `CKContainer` hits a hard trap (EXC_BREAKPOINT, uncatchable) when the app lacks the
/// iCloud entitlement, which is the normal state of unsigned CLI and simulator builds. iOS has no
/// public API to query entitlements, so we parse them out of the Mach-O: the code signature's
/// entitlements blob (devices, signed Macs) or the `__TEXT,__entitlements` section (simulator).
public struct Entitlements: Sendable {
    public let values: [String: any Sendable]

    public init(values: [String: any Sendable]) { self.values = values }

    /// Entitlements of the current process's main executable (empty if unreadable or unsigned).
    public static let current: Entitlements = {
        guard let path = Bundle.main.executablePath, let data = FileManager.default.contents(atPath: path) else {
            return Entitlements(values: [:])
        }
        return Entitlements(values: parse(executable: data) ?? [:])
    }()

    public func strings(_ key: String) -> [String] {
        if let list = values[key] as? [String] { return list }
        if let one = values[key] as? String { return [one] }
        return []
    }

    public func allowsCloudKit(container: String) -> Bool {
        strings("com.apple.developer.icloud-services").contains("CloudKit")
            && strings("com.apple.developer.icloud-container-identifiers").contains(container)
    }

    public var allowsKeyValueStore: Bool {
        values["com.apple.developer.ubiquity-kvstore-identifier"] != nil
    }

    // MARK: Mach-O parsing

    static func parse(executable data: Data) -> [String: any Sendable]? {
        let bytes = [UInt8](data)
        let magicBE = readBE32(bytes, 0)
        // Universal binary: check each slice.
        if magicBE == 0xCAFE_BABE || magicBE == 0xCAFE_BABF {
            let is64 = magicBE == 0xCAFE_BABF
            let count = Int(readBE32(bytes, 4))
            let entrySize = is64 ? 32 : 20
            for i in 0..<count {
                let e = 8 + i * entrySize
                let offset = is64 ? Int(readBE64(bytes, e + 8)) : Int(readBE32(bytes, e + 8))
                let size = is64 ? Int(readBE64(bytes, e + 16)) : Int(readBE32(bytes, e + 12))
                guard offset >= 0, size > 0, offset + size <= bytes.count else { continue }
                if let found = parseThin(Array(bytes[offset..<(offset + size)])) { return found }
            }
            return nil
        }
        return parseThin(bytes)
    }

    static func parseThin(_ b: [UInt8]) -> [String: any Sendable]? {
        guard b.count > 32, readLE32(b, 0) == 0xFEED_FACF else { return nil }   // 64-bit little-endian only
        let ncmds = Int(readLE32(b, 16))
        var p = 32
        var fromSection: [String: any Sendable]?
        for _ in 0..<ncmds {
            guard p + 8 <= b.count else { break }
            let cmd = readLE32(b, p), size = Int(readLE32(b, p + 4))
            guard size > 0 else { break }
            if cmd == 0x1D, p + 16 <= b.count {                        // LC_CODE_SIGNATURE
                let off = Int(readLE32(b, p + 8)), len = Int(readLE32(b, p + 12))
                if off + len <= b.count, let ent = parseSuperBlob(b, off, len) { return ent }
            } else if cmd == 0x19 {                                     // LC_SEGMENT_64
                let nsects = Int(readLE32(b, p + 64))
                for s in 0..<nsects {
                    let sp = p + 72 + s * 80
                    guard sp + 80 <= b.count else { break }
                    if cString(b, sp, 16) == "__entitlements" {
                        let size = Int(readLE64(b, sp + 40)), offset = Int(readLE32(b, sp + 48))
                        if offset > 0, offset + size <= b.count {
                            fromSection = plist(Array(b[offset..<(offset + size)]))
                        }
                    }
                }
            }
            p += size
        }
        return fromSection
    }

    /// Code-signature SuperBlob (big-endian). Entitlements blob magic: 0xFADE7171.
    static func parseSuperBlob(_ b: [UInt8], _ base: Int, _ length: Int) -> [String: any Sendable]? {
        guard length >= 12, readBE32(b, base) == 0xFADE_0CC0 else { return nil }
        let count = Int(readBE32(b, base + 8))
        for i in 0..<count {
            let idx = base + 12 + i * 8
            guard idx + 8 <= base + length else { break }
            let blob = base + Int(readBE32(b, idx + 4))
            guard blob + 8 <= b.count, readBE32(b, blob) == 0xFADE_7171 else { continue }
            let blobLen = Int(readBE32(b, blob + 4))
            guard blobLen > 8, blob + blobLen <= b.count else { continue }
            return plist(Array(b[(blob + 8)..<(blob + blobLen)]))
        }
        return nil
    }

    static func plist(_ bytes: [UInt8]) -> [String: any Sendable]? {
        guard let obj = try? PropertyListSerialization.propertyList(from: Data(bytes), format: nil),
              let dict = obj as? [String: Any] else { return nil }
        return dict.compactMapValues { value -> (any Sendable)? in
            switch value {
            case let s as String: s
            case let a as [String]: a
            case let n as NSNumber: n.boolValue
            default: String(describing: value)
            }
        }
    }

    private static func readLE32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    private static func readLE64(_ b: [UInt8], _ i: Int) -> UInt64 {
        UInt64(readLE32(b, i)) | UInt64(readLE32(b, i + 4)) << 32
    }
    private static func readBE32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
    private static func readBE64(_ b: [UInt8], _ i: Int) -> UInt64 {
        UInt64(readBE32(b, i)) << 32 | UInt64(readBE32(b, i + 4))
    }
    private static func cString(_ b: [UInt8], _ i: Int, _ max: Int) -> String {
        String(decoding: b[i..<(i + max)].prefix { $0 != 0 }, as: UTF8.self)
    }
}
