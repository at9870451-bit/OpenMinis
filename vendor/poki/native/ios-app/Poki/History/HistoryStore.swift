import Foundation
import SQLite3

/// One kept read of the screen: when, which app, the screen's title where the tree gave one, and
/// the screen's text.
struct HistoryEntry: Identifiable, Hashable {
    let id: Int64
    let at: Date
    let app: String
    let title: String
    let text: String
}

/// One line of the observing record: when reading was on, paused, blocked or left an app out.
struct HistoryRecord: Identifiable, Hashable {
    let id: Int64
    let at: Date
    let kind: String
    let detail: String
}

/// iPhone History's record (issue 356): text in one database in Poki's own container.
///
/// The file is unreadable while the iPhone is locked (complete file protection) and is left out of
/// iCloud and device backups. Nothing in it leaves the phone. Every call runs on one serial queue.
final class HistoryStore: @unchecked Sendable {
    static let shared = HistoryStore()

    private let queue = DispatchQueue(label: "nz.zheha.poki.history-store", qos: .utility)
    private var db: OpaquePointer?
    private var generation = UUID()
    private let folder: URL
    private let file: URL
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("History", isDirectory: true)
        file = folder.appendingPathComponent("history.sqlite")
    }

    // MARK: Opening

    /// Opens the database when it is not open. Fails while the phone is locked, and is tried again
    /// at the next call.
    private func open() -> Bool {
        if db != nil { return true }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var marked = folder
        try? marked.setResourceValues(values)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_FILEPROTECTION_COMPLETE
        guard sqlite3_open_v2(file.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return false
        }
        let schema = """
        CREATE TABLE IF NOT EXISTS entries (id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, app TEXT NOT NULL, title TEXT NOT NULL, text TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS entries_at ON entries (at);
        CREATE TABLE IF NOT EXISTS record (id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, kind TEXT NOT NULL, detail TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS record_at ON record (at);
        CREATE TABLE IF NOT EXISTS notes (start REAL PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL);
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return false
        }
        // The screen's tree beside its text (the owner, 2026-11-15). Fails once the column is there.
        sqlite3_exec(handle, "ALTER TABLE entries ADD COLUMN tree BLOB", nil, nil, nil)
        db = handle
        return true
    }

    /// Closes the file, as when the phone locks: an open file stays readable under file protection.
    func close() {
        queue.async {
            if let db = self.db { sqlite3_close(db) }
            self.db = nil
        }
    }

    // MARK: Statements

    private enum Bound {
        case text(String)
        case real(Double)
        case integer(Int64)
        case blob(Data?)
    }

    @discardableResult
    private func run(_ sql: String, _ values: [Bound] = []) -> Bool {
        guard open() else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func bind(_ statement: OpaquePointer?, _ values: [Bound]) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .integer(let number): sqlite3_bind_int64(statement, index, number)
            case .blob(let data):
                if let data, !data.isEmpty {
                    _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.transient) }
                } else {
                    sqlite3_bind_null(statement, index)
                }
            }
        }
    }

    private func rows<Row>(_ sql: String, _ values: [Bound] = [], _ make: (OpaquePointer) -> Row) -> [Row] {
        guard open() else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        var found: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW { found.append(make(statement)) }
        return found
    }

    private static func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private static func entry(_ statement: OpaquePointer) -> HistoryEntry {
        HistoryEntry(id: sqlite3_column_int64(statement, 0), at: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                     app: string(statement, 2), title: string(statement, 3), text: string(statement, 4))
    }

    // MARK: Writing

    /// `tree` is the launcher's compact tree as JSON; it is kept compressed.
    func add(at: Date, app: String, title: String, text: String, tree: Data? = nil) {
        queue.async {
            let packed = tree.flatMap { try? ($0 as NSData).compressed(using: .zlib) as Data }
            self.run("INSERT INTO entries (at, app, title, text, tree) VALUES (?, ?, ?, ?, ?)",
                     [.real(at.timeIntervalSince1970), .text(app), .text(title), .text(text), .blob(packed)])
        }
    }

    /// The compact tree of one read, as JSON rows `[depth, role, label, value, x, y, width, height]`.
    func tree(entry id: Int64) async -> Data? {
        await fetch {
            let packed = self.rows("SELECT tree FROM entries WHERE id = ?", [.integer(id)]) { statement -> Data? in
                guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
                return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            }.first ?? nil
            return packed.flatMap { try? ($0 as NSData).decompressed(using: .zlib) as Data }
        }
    }

    /// How many reads keep their tree, and the trees' bytes as stored.
    func trees() async -> (count: Int, bytes: Int64) {
        await fetch {
            self.rows("SELECT COUNT(tree), COALESCE(SUM(LENGTH(tree)), 0) FROM entries") {
                (count: Int(sqlite3_column_int64($0, 0)), bytes: sqlite3_column_int64($0, 1))
            }.first ?? (0, 0)
        }
    }

    func note(_ kind: String, _ detail: String = "", at: Date = Date()) {
        queue.async {
            self.run("INSERT INTO record (at, kind, detail) VALUES (?, ?, ?)", [.real(at.timeIntervalSince1970), .text(kind), .text(detail)])
        }
    }

    /// Forgets in layers, oldest first (the owner, 2026-11-15: a time limit and a storage limit,
    /// whichever is reached first; trees go first and the top summaries last).
    ///
    /// Past `days`: a read loses its tree and its screen text and keeps only when, which app and its
    /// title, so the library still shows the time; the 10 minute notes go, the hour, day and week
    /// summaries stay. Past `summaryDays` (never less than `days`) everything goes. Over
    /// `megabytes`: the oldest trees go, then the oldest screen text with its 10 minute notes, then
    /// the oldest reads and summaries whole.
    func prune(days: Int, summaryDays: Int = 0, megabytes: Int = 200) {
        queue.async {
            let now = Date().timeIntervalSince1970
            let cut = now - Double(days) * 86_400
            let end = now - Double(max(days, summaryDays)) * 86_400
            self.run("UPDATE entries SET tree = NULL, text = '' WHERE at < ? AND (tree IS NOT NULL OR text != '')", [.real(cut)])
            self.run("DELETE FROM notes WHERE start < ? AND start = CAST(start AS INTEGER)", [.real(cut)])
            self.run("DELETE FROM entries WHERE at < ?", [.real(end)])
            self.run("DELETE FROM notes WHERE start < ?", [.real(end)])
            self.run("DELETE FROM record WHERE at < ?", [.real(now - 30 * 86_400)])
            let limit = Int64(megabytes) * 1_048_576
            var rounds = 0
            while self.bytesNow() > limit, rounds < 40 {
                if self.any("SELECT 1 FROM entries WHERE tree IS NOT NULL LIMIT 1") {
                    self.run("UPDATE entries SET tree = NULL WHERE id IN (SELECT id FROM entries WHERE tree IS NOT NULL ORDER BY at LIMIT 3000)")
                } else if self.any("SELECT 1 FROM entries WHERE text != '' LIMIT 1") {
                    self.run("UPDATE entries SET text = '' WHERE id IN (SELECT id FROM entries WHERE text != '' ORDER BY at LIMIT 3000)")
                    self.run("DELETE FROM notes WHERE start = CAST(start AS INTEGER) AND start < COALESCE((SELECT MIN(at) FROM entries WHERE text != ''), ?)", [.real(now)])
                } else {
                    self.run("DELETE FROM entries WHERE id IN (SELECT id FROM entries ORDER BY at LIMIT 3000)")
                    self.run("DELETE FROM notes WHERE start < COALESCE((SELECT MIN(at) FROM entries), ?) - 8 * 86400", [.real(now)])
                    if !self.any("SELECT 1 FROM entries LIMIT 1") { self.run("DELETE FROM notes") }
                }
                self.run("VACUUM")
                rounds += 1
            }
        }
    }

    private func any(_ sql: String) -> Bool {
        !rows(sql) { _ in true }.isEmpty
    }

    func delete(from start: Date, to end: Date) async {
        await perform {
            self.generation = UUID()
            self.run("DELETE FROM entries WHERE at >= ? AND at < ?", [.real(start.timeIntervalSince1970), .real(end.timeIntervalSince1970)])
            self.run("DELETE FROM notes WHERE start >= ? AND start < ?", [.real(start.timeIntervalSince1970 - 600), .real(end.timeIntervalSince1970)])
            // Notes of an hour, a day or a week (kept a fraction of a second off the whole second,
            // see BacktapeZoom.key) that hold any of the forgotten time go too.
            self.run("DELETE FROM notes WHERE start != CAST(start AS INTEGER) AND start >= ? AND start < ?", [.real(start.timeIntervalSince1970 - 8 * 86_400), .real(end.timeIntervalSince1970)])
        }
    }

    /// Reads, summaries and the observing record: nothing is left.
    func deleteEverything() async {
        await perform {
            self.generation = UUID()
            self.run("DELETE FROM entries")
            self.run("DELETE FROM notes")
            self.run("DELETE FROM record")
            self.run("VACUUM")
        }
    }

    // MARK: Notes

    func summaryGeneration() async -> UUID {
        await fetch { self.generation }
    }

    /// Deletion and the generation check share the queue, including when a model ignores cancellation.
    @discardableResult
    func keep(_ note: BacktapeNote, start: Date, generation: UUID) async -> Bool {
        await fetch {
            guard generation == self.generation else { return false }
            return self.run("INSERT OR REPLACE INTO notes (start, title, body) VALUES (?, ?, ?)", [.real(start.timeIntervalSince1970), .text(note.title), .text(note.body)])
        }
    }

    func note(start: Date) async -> BacktapeNote? {
        await fetch {
            self.rows("SELECT title, body FROM notes WHERE start = ?", [.real(start.timeIntervalSince1970)]) {
                BacktapeNote(title: Self.string($0, 0), body: Self.string($0, 1))
            }.first
        }
    }

    /// The kept notes whose blocks start in a span, oldest first, with the key each was kept under.
    func notes(from start: Date, to end: Date) async -> [(start: Double, note: BacktapeNote)] {
        await fetch {
            self.rows("SELECT start, title, body FROM notes WHERE start >= ? AND start < ? ORDER BY start", [.real(start.timeIntervalSince1970), .real(end.timeIntervalSince1970)]) {
                (start: sqlite3_column_double($0, 0), note: BacktapeNote(title: Self.string($0, 1), body: Self.string($0, 2)))
            }
        }
    }

    // MARK: Reading

    /// The newest entries with only the start of their text, for the list of blocks.
    func recent(limit: Int = 60_000) async -> [HistoryEntry] {
        await fetch {
            self.rows("SELECT id, at, app, title, substr(text, 1, 240) FROM entries ORDER BY at DESC LIMIT ?", [.integer(Int64(limit))], Self.entry)
        }
    }

    /// Whole entries of one span, oldest first, for an opened block.
    func entries(from start: Date, to end: Date) async -> [HistoryEntry] {
        await fetch {
            self.rows("SELECT id, at, app, title, text FROM entries WHERE at >= ? AND at < ? ORDER BY at", [.real(start.timeIntervalSince1970), .real(end.timeIntervalSince1970)], Self.entry)
        }
    }

    /// Apps with kept reads, the most read first.
    func apps() async -> [String] {
        await fetch {
            self.rows("SELECT app FROM entries GROUP BY app ORDER BY COUNT(*) DESC LIMIT 200") { Self.string($0, 0) }.filter { !$0.isEmpty }
        }
    }

    func records(limit: Int = 500) async -> [HistoryRecord] {
        await fetch {
            self.rows("SELECT id, at, kind, detail FROM record ORDER BY at DESC, id DESC LIMIT ?", [.integer(Int64(limit))]) {
                HistoryRecord(id: sqlite3_column_int64($0, 0), at: Date(timeIntervalSince1970: sqlite3_column_double($0, 1)), kind: Self.string($0, 2), detail: Self.string($0, 3))
            }
        }
    }

    /// Entries kept and the file's size in bytes.
    func size() async -> (entries: Int, bytes: Int64) {
        await fetch {
            let count = self.rows("SELECT COUNT(*) FROM entries") { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
            return (count, self.bytesNow())
        }
    }

    private func bytesNow() -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func perform(_ work: @escaping () -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                work()
                done.resume()
            }
        }
    }

    private func fetch<Value>(_ work: @escaping () -> Value) async -> Value {
        await withCheckedContinuation { (done: CheckedContinuation<Value, Never>) in
            queue.async { done.resume(returning: work()) }
        }
    }
}
