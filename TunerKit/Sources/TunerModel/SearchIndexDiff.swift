/// What must change in a search index to go from `old` to `new`. Both map an item ID to a
/// signature of its searchable fields, so unrelated changes such as play counts cause no work.
public struct SearchIndexDiff: Equatable, Sendable {
    public let upserted: Set<String>
    public let removed: Set<String>

    public init(old: [String: String], new: [String: String]) {
        upserted = Set(new.filter { old[$0.key] != $0.value }.keys)
        removed = Set(old.keys).subtracting(new.keys)
    }
}
