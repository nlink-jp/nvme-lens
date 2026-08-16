import Foundation

/// A deliberately small TOML reader: `[section]` headers, `key = value` pairs,
/// `#` comments, and the three value kinds this tool's config actually uses
/// (integer, boolean, quoted string).
///
/// A full TOML implementation would be an external dependency, and ADR-0001
/// keeps runtime dependencies at zero. The config surface is a handful of
/// thresholds, so the subset is the honest scope — and anything outside it is
/// rejected loudly rather than silently ignored, because a threshold that was
/// quietly dropped is a monitor that quietly stops warning.
public enum TOMLLite {
    public enum Value: Equatable, Sendable {
        case integer(Int)
        case boolean(Bool)
        case string(String)
    }

    public enum ParseError: Error, Equatable, Sendable {
        case malformedLine(line: Int, text: String)
        case unclosedSection(line: Int, text: String)
        case unsupportedValue(line: Int, text: String)
        case duplicateKey(section: String, key: String, line: Int)
    }

    /// Section name → key → value. Keys outside any section land in `""`.
    public static func parse(_ text: String) throws -> [String: [String: Value]] {
        var table: [String: [String: Value]] = [:]
        var section = ""

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNumber = index + 1
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                guard line.hasSuffix("]"), line.count > 2 else {
                    throw ParseError.unclosedSection(line: lineNumber, text: line)
                }
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if table[section] == nil { table[section] = [:] }
                continue
            }

            guard let separator = line.firstIndex(of: "=") else {
                throw ParseError.malformedLine(line: lineNumber, text: line)
            }
            let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw ParseError.malformedLine(line: lineNumber, text: line) }

            guard let value = parseValue(rawValue) else {
                throw ParseError.unsupportedValue(line: lineNumber, text: line)
            }
            if table[section]?[key] != nil {
                throw ParseError.duplicateKey(section: section, key: key, line: lineNumber)
            }
            table[section, default: [:]][key] = value
        }
        return table
    }

    /// Strips a trailing `#` comment without cutting inside a quoted string.
    static func stripComment(_ line: String) -> String {
        var insideQuotes = false
        for (offset, character) in line.enumerated() {
            if character == "\"" { insideQuotes.toggle() }
            if character == "#" && !insideQuotes {
                return String(line.prefix(offset))
            }
        }
        return line
    }

    static func parseValue(_ raw: String) -> Value? {
        if raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 {
            return .string(String(raw.dropFirst().dropLast()))
        }
        if raw == "true" { return .boolean(true) }
        if raw == "false" { return .boolean(false) }
        if let integer = Int(raw) { return .integer(integer) }
        return nil
    }
}

extension TOMLLite.Value {
    public var integerValue: Int? {
        if case .integer(let value) = self { return value }
        return nil
    }
    public var booleanValue: Bool? {
        if case .boolean(let value) = self { return value }
        return nil
    }
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}
