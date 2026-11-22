import Foundation
import SQLite3

public struct StorageError: Error, LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

public enum AppJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let format = ISO8601DateFormatter()
            if let date = format.date(from: value) { return date }
            format.formatOptions.insert(.withFractionalSeconds)
            guard let date = format.date(from: value) else {
                throw StorageError("Invalid ISO 8601 date")
            }
            return date
        }
        return decoder
    }
}

public actor StateStore<State: Codable & Sendable> {
    public typealias Validate = @Sendable (inout State) throws -> Void

    private let url: URL
    private var state: State

    public init(directory: URL, defaultState: @autoclosure () -> State) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appending(path: "aides.sqlite3")
        self.url = url
        state = try Self.withDatabase(at: url) { database in
            try Self.execute("PRAGMA journal_mode=WAL", on: database)
            try Self.execute("PRAGMA synchronous=FULL", on: database)
            try Self.execute(
                "CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK (id = 1), payload BLOB NOT NULL)",
                on: database
            )
            let payload: Data? = try Self.statement("SELECT payload FROM state WHERE id = 1", on: database) { query in
                switch sqlite3_step(query) {
                case SQLITE_DONE: return nil
                case SQLITE_ROW:
                    guard let bytes = sqlite3_column_blob(query, 0) else {
                        throw StorageError("Persistent state is empty")
                    }
                    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0)))
                default: throw Self.failure(database)
                }
            }
            if let payload { return try AppJSON.decoder().decode(State.self, from: payload) }
            let initial = defaultState()
            try Self.save(initial, on: database)
            return initial
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func snapshot() -> State { state }

    @discardableResult
    public func update<Result: Sendable>(_ change: @Sendable (inout State) throws -> Result) throws -> Result {
        var updated = state
        let result = try change(&updated)
        try Self.withDatabase(at: url) { database in
            try Self.execute("PRAGMA synchronous=FULL", on: database)
            try Self.save(updated, on: database)
        }
        state = updated
        return result
    }

    private static func save(_ state: State, on database: OpaquePointer) throws {
        let payload = try AppJSON.encoder().encode(state)
        try statement(
            "INSERT INTO state VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", on: database
        ) { query in
            try payload.withUnsafeBytes { buffer in
                guard sqlite3_bind_blob(query, 1, buffer.baseAddress, Int32(buffer.count), nil) == SQLITE_OK,
                      sqlite3_step(query) == SQLITE_DONE else { throw failure(database) }
                sqlite3_reset(query)
                sqlite3_clear_bindings(query)
            }
        }
    }

    private static func withDatabase<Result>(at url: URL, _ body: (OpaquePointer) throws -> Result) throws -> Result {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        defer { sqlite3_close(handle) }
        guard let handle, result == SQLITE_OK else { throw StorageError("Could not open local database") }
        sqlite3_busy_timeout(handle, 3_000)
        return try body(handle)
    }

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure(database) }
    }

    private static func statement<Result>(
        _ sql: String, on database: OpaquePointer, _ body: (OpaquePointer) throws -> Result
    ) throws -> Result {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &query, nil) == SQLITE_OK, let query else {
            throw failure(database)
        }
        defer { sqlite3_finalize(query) }
        return try body(query)
    }

    private static func failure(_ database: OpaquePointer) -> StorageError {
        StorageError(String(cString: sqlite3_errmsg(database)))
    }
}
