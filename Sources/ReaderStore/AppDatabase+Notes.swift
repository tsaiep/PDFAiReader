import Foundation
import GRDB
import ReaderCore

extension StickyNote: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "sticky_notes" }
}

extension Highlight: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "highlights" }
}

// MARK: - 便利貼與螢光筆

extension AppDatabase {
    public func notes(documentID: String) throws -> [StickyNote] {
        try writer.read { db in
            try StickyNote
                .filter(Column("documentID") == documentID)
                .order(Column("pageIndex"), Column("createdAt"))
                .fetchAll(db)
        }
    }

    public func saveNote(_ note: StickyNote) throws {
        try writer.write { db in try note.upsert(db) }
    }

    public func deleteNote(id: String) throws {
        _ = try writer.write { db in try StickyNote.deleteOne(db, key: id) }
    }

    public func highlights(documentID: String) throws -> [Highlight] {
        try writer.read { db in
            try Highlight
                .filter(Column("documentID") == documentID)
                .order(Column("pageIndex"), Column("createdAt"))
                .fetchAll(db)
        }
    }

    public func saveHighlight(_ highlight: Highlight) throws {
        try writer.write { db in try highlight.upsert(db) }
    }

    public func deleteHighlight(id: String) throws {
        _ = try writer.write { db in try Highlight.deleteOne(db, key: id) }
    }
}
