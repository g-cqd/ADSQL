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

    public var ftsTables: [FTSTable]
    /// Regular source tables to NOT import (beyond the auto-skipped FTS shadow
    /// tables): irrelevant/large tables a consumer doesn't need (e.g. a vectors or
    /// zstd-payload table). Auto-introspection imports every regular table except
    /// these + the FTS shadows.
    public var skipTables: [String]
    public init(ftsTables: [FTSTable] = [], skipTables: [String] = []) {
        self.ftsTables = ftsTables
        self.skipTables = skipTables
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
