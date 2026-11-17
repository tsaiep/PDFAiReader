import Foundation
import GRDB
import ReaderCore

/// App 的 SQLite 資料庫。所有讀寫都經過這裡。
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// ~/Library/Application Support/PDFAiReader/reader.sqlite
    public static func openDefault() throws -> AppDatabase {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                 appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("PDFAiReader", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("reader.sqlite")
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: config)
        return try AppDatabase(pool)
    }

    public static func inMemory() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(DatabaseQueue(configuration: config))
    }

    // MARK: - Migrations（只能新增，不可修改已發佈的 migration）

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = false
        #endif

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE documents (
                id TEXT PRIMARY KEY NOT NULL,
                path TEXT NOT NULL,
                bookmarkData BLOB,
                title TEXT NOT NULL,
                pageCount INTEGER NOT NULL,
                fileSize INTEGER NOT NULL,
                lastOpenedAt DATETIME NOT NULL
            );

            CREATE TABLE reading_progress (
                documentID TEXT PRIMARY KEY NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                pageIndex INTEGER NOT NULL,
                scaleFactor DOUBLE NOT NULL,
                autoScales BOOLEAN NOT NULL,
                displayMode TEXT NOT NULL,
                readingDirection TEXT NOT NULL,
                updatedAt DATETIME NOT NULL
            );

            CREATE TABLE bookmarks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                documentID TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                pageIndex INTEGER NOT NULL,
                title TEXT NOT NULL,
                createdAt DATETIME NOT NULL
            );
            CREATE INDEX bookmarks_document ON bookmarks(documentID, pageIndex);

            CREATE TABLE pages (
                documentID TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                pageIndex INTEGER NOT NULL,
                width DOUBLE NOT NULL,
                height DOUBLE NOT NULL,
                rotation INTEGER NOT NULL DEFAULT 0,
                textSource TEXT,
                ocrState TEXT NOT NULL DEFAULT 'none',
                ocrConfidence DOUBLE,
                PRIMARY KEY (documentID, pageIndex)
            );

            CREATE TABLE text_blocks (
                id TEXT PRIMARY KEY NOT NULL,
                documentID TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                pageIndex INTEGER NOT NULL,
                readingOrder INTEGER NOT NULL,
                kind TEXT NOT NULL,
                text TEXT NOT NULL,
                bounds TEXT NOT NULL,
                confidence DOUBLE NOT NULL,
                source TEXT NOT NULL,
                textHash TEXT,
                userEdited BOOLEAN NOT NULL DEFAULT 0
            );
            CREATE INDEX text_blocks_page ON text_blocks(documentID, pageIndex, readingOrder);

            CREATE TABLE translations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                blockID TEXT NOT NULL,
                documentID TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                pageIndex INTEGER NOT NULL,
                sourceHash TEXT NOT NULL,
                targetLanguage TEXT NOT NULL,
                engine TEXT NOT NULL,
                model TEXT NOT NULL,
                promptVersion TEXT NOT NULL,
                contextVersion TEXT NOT NULL,
                translation TEXT NOT NULL,
                createdAt DATETIME NOT NULL,
                UNIQUE (blockID, sourceHash, targetLanguage, engine, model, promptVersion, contextVersion)
            );
            CREATE INDEX translations_page ON translations(documentID, pageIndex);

            CREATE TABLE translation_jobs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                documentID TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                pageIndex INTEGER,
                blockIDs TEXT,
                kind TEXT NOT NULL,
                priority INTEGER NOT NULL,
                state TEXT NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                engine TEXT,
                model TEXT,
                errorMessage TEXT,
                createdAt DATETIME NOT NULL,
                startedAt DATETIME,
                finishedAt DATETIME
            );
            CREATE INDEX translation_jobs_queue ON translation_jobs(state, priority, createdAt);

            CREATE TABLE annotations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                documentID TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                pageIndex INTEGER NOT NULL,
                kind TEXT NOT NULL,
                bounds TEXT,
                selectedText TEXT,
                note TEXT,
                color TEXT,
                createdAt DATETIME NOT NULL,
                updatedAt DATETIME NOT NULL
            );

            CREATE TABLE preferences (
                scope TEXT NOT NULL,
                key TEXT NOT NULL,
                value TEXT NOT NULL,
                PRIMARY KEY (scope, key)
            );

            CREATE TABLE glossary (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                documentID TEXT REFERENCES documents(id) ON DELETE CASCADE,
                source TEXT NOT NULL,
                target TEXT NOT NULL,
                note TEXT,
                updatedAt DATETIME NOT NULL
            );
            """)
        }

        migrator.registerMigration("v2-page-translation-status") { db in
            try db.execute(sql: """
            CREATE TABLE page_translation_status (
                documentID TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                pageIndex INTEGER NOT NULL,
                cacheKey TEXT NOT NULL,
                state TEXT NOT NULL,
                errorMessage TEXT,
                updatedAt DATETIME NOT NULL,
                PRIMARY KEY (documentID, pageIndex, cacheKey)
            );
            CREATE INDEX translations_block ON translations(blockID);
            """)
        }

        migrator.registerMigration("v3-notes-highlights") { db in
            try db.execute(sql: """
            CREATE TABLE sticky_notes (
                id TEXT PRIMARY KEY NOT NULL,
                documentID TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                pageIndex INTEGER NOT NULL,
                rect TEXT,
                title TEXT NOT NULL DEFAULT '',
                body TEXT NOT NULL DEFAULT '',
                color TEXT NOT NULL,
                fontFamily TEXT NOT NULL DEFAULT '',
                fontSize DOUBLE NOT NULL,
                expanded BOOLEAN NOT NULL DEFAULT 0,
                createdAt DATETIME NOT NULL,
                updatedAt DATETIME NOT NULL
            );
            CREATE INDEX sticky_notes_page ON sticky_notes(documentID, pageIndex);

            CREATE TABLE highlights (
                id TEXT PRIMARY KEY NOT NULL,
                documentID TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                pageIndex INTEGER NOT NULL,
                color TEXT NOT NULL,
                rects TEXT NOT NULL,
                text TEXT NOT NULL DEFAULT '',
                createdAt DATETIME NOT NULL
            );
            CREATE INDEX highlights_page ON highlights(documentID, pageIndex);
            """)
        }

        migrator.registerMigration("v4-highlight-spans") { db in
            try db.execute(sql: "ALTER TABLE highlights ADD COLUMN spans TEXT NOT NULL DEFAULT '[]'")
        }

        migrator.registerMigration("v5-note-order") { db in
            try db.execute(sql: "ALTER TABLE sticky_notes ADD COLUMN sortOrder DOUBLE NOT NULL DEFAULT 0")
            try db.execute(sql: "UPDATE sticky_notes SET sortOrder = CAST(strftime('%s', createdAt) AS DOUBLE)")
        }
        return migrator
    }
}

// MARK: - Record conformances

extension DocumentRecord: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "documents" }
}

extension ReadingProgress: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "reading_progress" }
}

extension Bookmark: FetchableRecord, MutablePersistableRecord {
    public static var databaseTableName: String { "bookmarks" }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Documents / Progress / Bookmarks

extension AppDatabase {
    public func upsertDocument(_ doc: DocumentRecord) throws {
        try writer.write { db in
            try doc.upsert(db)
        }
    }

    public func document(id: String) throws -> DocumentRecord? {
        try writer.read { db in try DocumentRecord.fetchOne(db, key: id) }
    }

    public func recentDocuments(limit: Int = 20) throws -> [DocumentRecord] {
        try writer.read { db in
            try DocumentRecord
                .order(Column("lastOpenedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func removeDocument(id: String) throws {
        _ = try writer.write { db in try DocumentRecord.deleteOne(db, key: id) }
    }

    public func saveProgress(_ progress: ReadingProgress) throws {
        try writer.write { db in try progress.upsert(db) }
    }

    public func progress(documentID: String) throws -> ReadingProgress? {
        try writer.read { db in try ReadingProgress.fetchOne(db, key: documentID) }
    }

    public func bookmarks(documentID: String) throws -> [Bookmark] {
        try writer.read { db in
            try Bookmark
                .filter(Column("documentID") == documentID)
                .order(Column("pageIndex"))
                .fetchAll(db)
        }
    }

    @discardableResult
    public func addBookmark(_ bookmark: Bookmark) throws -> Bookmark {
        try writer.write { db in
            var b = bookmark
            try b.insert(db)
            return b
        }
    }

    public func deleteBookmark(id: Int64) throws {
        _ = try writer.write { db in try Bookmark.deleteOne(db, key: id) }
    }

    // MARK: Preferences（scope = "global" 或文件 ID）

    public func preference(_ key: String, scope: String = "global") throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM preferences WHERE scope = ? AND key = ?",
                                arguments: [scope, key])
        }
    }

    public func setPreference(_ key: String, value: String?, scope: String = "global") throws {
        try writer.write { db in
            if let value {
                try db.execute(sql: """
                INSERT INTO preferences(scope, key, value) VALUES (?, ?, ?)
                ON CONFLICT(scope, key) DO UPDATE SET value = excluded.value
                """, arguments: [scope, key, value])
            } else {
                try db.execute(sql: "DELETE FROM preferences WHERE scope = ? AND key = ?",
                               arguments: [scope, key])
            }
        }
    }
}
