import ADSQLKernel

/// Describes the FTS5 tables to reconstruct during import. SQLite's FTS5
/// tokenize/config is not fully introspectable from the `.db` file, so the
/// importer needs this explicit manifest. Regular tables are auto-introspected
/// and need no entry. `Codable` so the CLI can read it as JSON; the test builds
/// it directly.
public struct ImportManifest: Sendable, Codable {
    /// One FTS5 table: its FTS columns + tokenizer + content mode, plus the
    /// **source** (a SQLite table + parallel columns) the indexed text is read
    /// from — e.g. `documents_fts` ← `documents.[title,abstract,declaration,
    /// headings,key]`, `documents_trigram` ← `documents.[title]`.
    public struct FTSTable: Sendable, Codable {
        public var name: String
        public var columns: [String]
        public var tokenize: [String]
        public var content: ContentMode
        public var source: Source
        public var prefix: [Int]
        public var detail: Detail

        public init(
            name: String, columns: [String], tokenize: [String], content: ContentMode = .selfContained,
            source: Source, prefix: [Int] = [], detail: Detail = .full
        ) {
            self.name = name
            self.columns = columns
            self.tokenize = tokenize
            self.content = content
            self.source = source
            self.prefix = prefix
            self.detail = detail
        }
    }

    public enum ContentMode: Sendable, Codable {
        case selfContained
        case external(table: String, rowid: String)
        case contentless(deleteEnabled: Bool)
    }

    public struct Source: Sendable, Codable {
        public var table: String
        public var columns: [String]
        public init(table: String, columns: [String]) {
            self.table = table
            self.columns = columns
        }
    }

    public enum Detail: String, Sendable, Codable { case full, column, none }

    /// JSON-friendly column type (`ColumnType` is a non-`Codable` `UInt8` enum).
    public enum TypeName: String, Sendable, Codable {
        case integer, real, text, blob
        var columnType: ColumnType {
            switch self {
            case .integer: .integer
            case .real: .real
            case .text: .text
            case .blob: .blob
            }
        }
    }

    /// Build-time denormalization (RFC 0010 F6): extra columns the importer creates
    /// WITH `table` (ADSQL has no `ALTER TABLE`) and populates by `UPDATE` AFTER the
    /// row copy + all other tables exist (a lookup reads another imported table). Lets
    /// a consumer serve a denormalized read query with no per-row `LOWER`/`json_extract`
    /// or JOIN — the F6 win on apple-docs `/search` (≈2.2× vs SQLite at 8-way, RFC §6).
    public struct Denorm: Sendable, Codable {
        public var table: String
        /// Per-row computed columns: `name` ← `valueSQL` (an expression over the row,
        /// e.g. `LOWER(title)`), applied as one `UPDATE <table> SET name = valueSQL, …`.
        public var columns: [Column]
        /// Lookup columns: `name` ← the `lookupValue` of the `lookupTable` row whose
        /// `lookupKey` == this row's `matchColumn`, else `fallbackColumn`. (ADSQL has no
        /// correlated-subquery `UPDATE`, so the importer iterates the small lookup table.)
        public var lookups: [Lookup]

        public struct Column: Sendable, Codable {
            public var name: String
            public var type: TypeName
            public var valueSQL: String
            public init(name: String, type: TypeName, valueSQL: String) {
                self.name = name
                self.type = type
                self.valueSQL = valueSQL
            }
        }
        public struct Lookup: Sendable, Codable {
            public var name: String
            public var type: TypeName
            public var matchColumn: String
            public var lookupTable: String
            public var lookupKey: String
            public var lookupValue: String
            public var fallbackColumn: String
            public init(
                name: String, type: TypeName, matchColumn: String, lookupTable: String,
                lookupKey: String, lookupValue: String, fallbackColumn: String
            ) {
                self.name = name
                self.type = type
                self.matchColumn = matchColumn
                self.lookupTable = lookupTable
                self.lookupKey = lookupKey
                self.lookupValue = lookupValue
                self.fallbackColumn = fallbackColumn
            }
        }
        public init(table: String, columns: [Column] = [], lookups: [Lookup] = []) {
            self.table = table
            self.columns = columns
            self.lookups = lookups
        }

        /// The nullable column definitions appended to `table` (populated post-copy).
        var columnDefinitions: [ColumnDefinition] {
            columns.map { ColumnDefinition($0.name, $0.type.columnType, notNull: false) }
                + lookups.map { ColumnDefinition($0.name, $0.type.columnType, notNull: false) }
        }
    }

    public var ftsTables: [FTSTable]
    /// Regular source tables to NOT import (beyond the auto-skipped FTS shadow
    /// tables): irrelevant/large tables a consumer doesn't need (e.g. a vectors or
    /// zstd-payload table). Auto-introspection imports every regular table except
    /// these + the FTS shadows.
    public var skipTables: [String]
    /// Build-time denormalization to apply after import (F6), keyed by table.
    public var denorm: [Denorm]
    public init(ftsTables: [FTSTable] = [], skipTables: [String] = [], denorm: [Denorm] = []) {
        self.ftsTables = ftsTables
        self.skipTables = skipTables
        self.denorm = denorm
    }

    public static let empty = ImportManifest()

    /// The explicit `skipTables` plus every declared FTS table's name + shadow-table
    /// names, to skip during the regular (auto-introspected) table pass.
    var skipTableNames: Set<String> {
        var skip = Set(skipTables)
        for table in ftsTables {
            skip.insert(table.name)
            for suffix in ["_data", "_idx", "_content", "_docsize", "_config"] {
                skip.insert(table.name + suffix)
            }
            if case .external(let backing, _) = table.content { _ = backing }
        }
        return skip
    }
}

extension ImportManifest.FTSTable {
    /// The kernel `FTSDefinition` this entry creates.
    var ftsDefinition: FTSDefinition {
        let contentMode: FTSContentMode =
            switch content {
            case .selfContained: .selfContained
            case .external(let table, let rowid): .external(table: table, rowid: rowid)
            case .contentless(let deleteEnabled): .contentless(deleteEnabled: deleteEnabled)
            }
        let ftsDetail: FTSDetail =
            switch detail {
            case .full: .full
            case .column: .column
            case .none: FTSDetail.none
            }
        return FTSDefinition(
            name: name, columns: columns, tokenize: tokenize, content: contentMode,
            prefix: prefix, detail: ftsDetail)
    }
}
