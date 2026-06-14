/// The MATCH query language (M5/F3a). Parses an FTS5-style query string into an
/// operator tree; boolean evaluation over postings (F3b) and the SQL `MATCH`
/// surface (F3c) build on it. Grammar (precedence high→low): column filter
/// `col:` / `{a b}:` > `NOT` > `AND` (incl. implicit AND between adjacent terms)
/// > `OR`. `AND`/`OR`/`NOT` are case-sensitive uppercase keywords (FTS5).
///
/// A `phrase`'s `text` is the raw query token(s) — the table's tokenizer is
/// applied at evaluation, so `Running` matches the stemmed `run`, and a quoted
/// `"a b"` becomes an ordered adjacency. `prefix` marks a trailing `*`.
indirect enum FTSQuery: Equatable, Sendable {
    case phrase(text: String, prefix: Bool)
    case and(FTSQuery, FTSQuery)
    case or(FTSQuery, FTSQuery)
    case not(FTSQuery, FTSQuery)
    case column(columns: [String], FTSQuery)

    static func parse(_ query: String) throws(DBError) -> FTSQuery {
        var parser = MatchParser(tokens: MatchLexer.tokenize(Array(query.utf8)))
        let expr = try parser.parseOr()
        guard parser.atEnd else {
            throw DBError.sqlSyntax(message: "unexpected trailing tokens in MATCH query", offset: 0)
        }
        return expr
    }
}

private enum MatchToken: Equatable {
    case word(String)
    case string(String)
    case and, or, not
    case lparen, rparen, lbrace, rbrace, colon, star
}

private enum MatchLexer {
    static func isSpecial(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x20, 0x09, 0x0A, 0x0D,
            UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "{"), UInt8(ascii: "}"),
            UInt8(ascii: ":"), UInt8(ascii: "*"), UInt8(ascii: "\""):
            return true
        default:
            return false
        }
    }

    static func tokenize(_ bytes: [UInt8]) -> [MatchToken] {
        var tokens: [MatchToken] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            case UInt8(ascii: "("):
                tokens.append(.lparen)
                index += 1
            case UInt8(ascii: ")"):
                tokens.append(.rparen)
                index += 1
            case UInt8(ascii: "{"):
                tokens.append(.lbrace)
                index += 1
            case UInt8(ascii: "}"):
                tokens.append(.rbrace)
                index += 1
            case UInt8(ascii: ":"):
                tokens.append(.colon)
                index += 1
            case UInt8(ascii: "*"):
                tokens.append(.star)
                index += 1
            case UInt8(ascii: "\""):
                index += 1
                let start = index
                while index < bytes.count, bytes[index] != UInt8(ascii: "\"") { index += 1 }
                tokens.append(.string(String(decoding: bytes[start..<index], as: UTF8.self)))
                if index < bytes.count { index += 1 }  // closing quote
            default:
                let start = index
                while index < bytes.count, !isSpecial(bytes[index]) { index += 1 }
                let word = String(decoding: bytes[start..<index], as: UTF8.self)
                switch word {
                case "AND": tokens.append(.and)
                case "OR": tokens.append(.or)
                case "NOT": tokens.append(.not)
                default: tokens.append(.word(word))
                }
            }
        }
        return tokens
    }
}

private struct MatchParser {
    let tokens: [MatchToken]
    var pos = 0

    var current: MatchToken? { pos < tokens.count ? tokens[pos] : nil }
    var atEnd: Bool { pos >= tokens.count }

    mutating func parseOr() throws(DBError) -> FTSQuery {
        var lhs = try parseAnd()
        while case .or = current {
            pos += 1
            lhs = .or(lhs, try parseAnd())
        }
        return lhs
    }

    mutating func parseAnd() throws(DBError) -> FTSQuery {
        var lhs = try parseNot()
        while true {
            if case .and = current {
                pos += 1
                lhs = .and(lhs, try parseNot())
            } else if startsPrimary(current) {
                lhs = .and(lhs, try parseNot())  // implicit AND between adjacent terms
            } else {
                break
            }
        }
        return lhs
    }

    mutating func parseNot() throws(DBError) -> FTSQuery {
        var lhs = try parsePrimary()
        while case .not = current {
            pos += 1
            lhs = .not(lhs, try parsePrimary())
        }
        return lhs
    }

    mutating func parsePrimary() throws(DBError) -> FTSQuery {
        guard let token = current else {
            throw DBError.sqlSyntax(message: "unexpected end of MATCH query", offset: 0)
        }
        switch token {
        case .lparen:
            pos += 1
            let expr = try parseOr()
            guard case .rparen = current else {
                throw DBError.sqlSyntax(message: "expected ')' in MATCH query", offset: 0)
            }
            pos += 1
            return expr
        case .lbrace:
            pos += 1
            var columns: [String] = []
            while case .word(let name) = current {
                columns.append(name)
                pos += 1
            }
            guard case .rbrace = current else {
                throw DBError.sqlSyntax(message: "expected '}' in MATCH column filter", offset: 0)
            }
            pos += 1
            guard case .colon = current else {
                throw DBError.sqlSyntax(message: "expected ':' after MATCH column filter", offset: 0)
            }
            pos += 1
            return .column(columns: columns, try parsePrimary())
        case .string(let text):
            pos += 1
            return .phrase(text: text, prefix: consumeStar())
        case .word(let word):
            pos += 1
            if case .colon = current {
                pos += 1
                return .column(columns: [word], try parsePrimary())
            }
            return .phrase(text: word, prefix: consumeStar())
        default:
            throw DBError.sqlSyntax(message: "unexpected token in MATCH query", offset: 0)
        }
    }

    mutating func consumeStar() -> Bool {
        if case .star = current {
            pos += 1
            return true
        }
        return false
    }

    func startsPrimary(_ token: MatchToken?) -> Bool {
        switch token {
        case .word, .string, .lparen, .lbrace: return true
        default: return false
        }
    }
}
