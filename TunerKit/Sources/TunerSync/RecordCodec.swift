import CloudKit
import Foundation
import TunerModel
import TunerStore

/// Maps synced rows to and from `CKRecord`s in Tuner's private custom zone.
public enum RecordCodec {
    public static let zoneName = "TunerState"
    public static var defaultZoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName) }

    /// Bumped if the record layout changes; older clients ignore records from a newer schema.
    static let schemaVersion: Int64 = 1

    enum Key {
        static let schema = "schema"
        // Station
        static let payload = "payload"          // JSON-encoded `Station`
        static let name = "name"                // duplicated for readability in the CloudKit console
        static let isFavorite = "isFavorite"
        static let isCustom = "isCustom"
        static let sortIndex = "sortIndex"
        static let addedAt = "addedAt"
        static let lastPlayedAt = "lastPlayedAt"
        static let modifiedAt = "modifiedAt"
        // Identified song
        static let title = "title"
        static let artist = "artist"
        static let artworkURL = "artworkURL"
        static let stationName = "stationName"
        static let identifiedAt = "identifiedAt"
        static let libraryTrackID = "libraryTrackID"
    }

    public static func recordID(for name: SyncRecordName, zoneID: CKRecordZone.ID = defaultZoneID) -> CKRecord.ID {
        CKRecord.ID(recordName: name.description, zoneID: zoneID)
    }

    public static func name(of recordID: CKRecord.ID) -> SyncRecordName? { SyncRecordName(recordID.recordName) }

    /// Builds the record to upload. Starting from stored system fields keeps the server change tag,
    /// so CloudKit can detect conflicting writes instead of silently overwriting.
    public static func record(for item: SyncItem, zoneID: CKRecordZone.ID = defaultZoneID, systemFields: Data? = nil) -> CKRecord {
        let id = recordID(for: item.name, zoneID: zoneID)
        let record: CKRecord
        if let systemFields, let base = decodeSystemFields(systemFields), base.recordID == id {
            record = base
        } else {
            record = CKRecord(recordType: item.name.type.rawValue, recordID: id)
        }
        write(item, into: record)
        return record
    }

    /// Copies `item`'s fields onto an existing record (e.g. the server's copy after a conflict).
    public static func write(_ item: SyncItem, into record: CKRecord) {
        record[Key.schema] = schemaVersion
        switch item {
        case .station(let s):
            record[Key.payload] = (try? JSONEncoder().encode(s.station)) ?? Data()
            record[Key.name] = s.station.name
            record[Key.isFavorite] = s.isFavorite ? 1 : 0 as Int64
            record[Key.isCustom] = s.isCustom ? 1 : 0 as Int64
            record[Key.sortIndex] = s.sortIndex
            record[Key.addedAt] = s.addedAt
            record[Key.lastPlayedAt] = s.lastPlayedAt
            record[Key.modifiedAt] = s.modifiedAt
        case .identifiedSong(let song):
            record[Key.title] = song.title
            record[Key.artist] = song.artist
            record[Key.artworkURL] = song.artworkURL?.absoluteString
            record[Key.stationName] = song.stationName
            record[Key.identifiedAt] = song.identifiedAt
            record[Key.libraryTrackID] = song.libraryTrackID
            record[Key.modifiedAt] = song.identifiedAt
        }
    }

    /// Decodes a fetched record. Returns nil for unknown types, newer schemas or malformed records.
    public static func item(from record: CKRecord) -> SyncItem? {
        guard let name = name(of: record.recordID), record.recordType == name.type.rawValue else { return nil }
        if let schema = record[Key.schema] as? Int64, schema > schemaVersion { return nil }

        switch name.type {
        case .station:
            guard let payload = record[Key.payload] as? Data,
                  let station = try? JSONDecoder().decode(Station.self, from: payload),
                  station.id == name.localID,
                  let modifiedAt = record[Key.modifiedAt] as? Date else { return nil }
            return .station(SyncedStation(
                station: station,
                isFavorite: (record[Key.isFavorite] as? Int64 ?? 0) != 0,
                isCustom: (record[Key.isCustom] as? Int64 ?? 0) != 0,
                sortIndex: record[Key.sortIndex] as? Double ?? 0,
                addedAt: record[Key.addedAt] as? Date ?? modifiedAt,
                lastPlayedAt: record[Key.lastPlayedAt] as? Date,
                modifiedAt: modifiedAt
            ))
        case .identifiedSong:
            guard let uuid = uuid(fromHex: name.localID),
                  let title = record[Key.title] as? String,
                  let identifiedAt = record[Key.identifiedAt] as? Date else { return nil }
            var song = IdentifiedSong(
                id: uuid, title: title, artist: record[Key.artist] as? String,
                artworkURL: (record[Key.artworkURL] as? String).flatMap(URL.init(string:)),
                stationName: record[Key.stationName] as? String, identifiedAt: identifiedAt
            )
            song.libraryTrackID = record[Key.libraryTrackID] as? String
            return .identifiedSong(song)
        }
    }

    static func uuid(fromHex hex: String) -> UUID? {
        guard hex.count == 32 else { return nil }
        var s = hex
        for i in [8, 13, 18, 23] { s.insert("-", at: s.index(s.startIndex, offsetBy: i)) }
        return UUID(uuidString: s)
    }

    public static func encodeSystemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    public static func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
}
