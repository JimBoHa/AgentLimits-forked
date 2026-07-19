import Foundation

nonisolated enum CLIArgumentParserError: LocalizedError, Equatable {
    case unterminatedSingleQuote
    case unterminatedDoubleQuote
    case trailingEscape
    case nullByte

    var errorDescription: String? {
        switch self {
        case .unterminatedSingleQuote:
            return "Additional arguments contain an unterminated single quote."
        case .unterminatedDoubleQuote:
            return "Additional arguments contain an unterminated double quote."
        case .trailingEscape:
            return "Additional arguments end with an incomplete escape."
        case .nullByte:
            return "Additional arguments contain an unsupported null byte."
        }
    }
}

/// Parses a user-facing argument field without evaluating any shell syntax.
/// Quotes and backslashes group literal characters; substitutions, redirects,
/// pipelines, and command separators remain ordinary argument text.
nonisolated enum CLIArgumentParser {
    private enum State {
        case unquoted
        case singleQuoted
        case doubleQuoted
        case escapedUnquoted
        case escapedDoubleQuoted
    }

    static func parse(_ source: String) throws -> [String] {
        var arguments: [String] = []
        var current = ""
        var state = State.unquoted
        var tokenStarted = false

        func appendCurrentArgument() {
            guard tokenStarted else { return }
            arguments.append(current)
            current = ""
            tokenStarted = false
        }

        for character in source {
            guard character != "\0" else {
                throw CLIArgumentParserError.nullByte
            }

            switch state {
            case .unquoted:
                if character.isWhitespace {
                    appendCurrentArgument()
                } else if character == "'" {
                    tokenStarted = true
                    state = .singleQuoted
                } else if character == "\"" {
                    tokenStarted = true
                    state = .doubleQuoted
                } else if character == "\\" {
                    tokenStarted = true
                    state = .escapedUnquoted
                } else {
                    tokenStarted = true
                    current.append(character)
                }

            case .singleQuoted:
                if character == "'" {
                    state = .unquoted
                } else {
                    current.append(character)
                }

            case .doubleQuoted:
                if character == "\"" {
                    state = .unquoted
                } else if character == "\\" {
                    state = .escapedDoubleQuoted
                } else {
                    current.append(character)
                }

            case .escapedUnquoted:
                current.append(character)
                state = .unquoted

            case .escapedDoubleQuoted:
                switch character {
                case "$", "`", "\"", "\\":
                    current.append(character)
                case "\n":
                    break
                default:
                    current.append("\\")
                    current.append(character)
                }
                state = .doubleQuoted
            }
        }

        switch state {
        case .unquoted:
            appendCurrentArgument()
        case .singleQuoted:
            throw CLIArgumentParserError.unterminatedSingleQuote
        case .doubleQuoted:
            throw CLIArgumentParserError.unterminatedDoubleQuote
        case .escapedUnquoted, .escapedDoubleQuoted:
            throw CLIArgumentParserError.trailingEscape
        }
        return arguments
    }
}

/// A command represented as an executable and literal argv entries.
nonisolated struct CLICommandInvocation: Equatable {
    let executable: String
    let arguments: [String]

    /// Renders argv for the small number of features that still need a shell
    /// wrapper for PATH setup, timeout handling, or live log piping.
    var shellCommand: String {
        ([executable] + arguments)
            .map(Self.shellQuote)
            .joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let isSafeUnquoted = value.utf8.allSatisfy { byte in
            switch byte {
            case 45, 46, 47, 48...57, 58, 64...90, 95, 97...122:
                return true
            default:
                return false
            }
        }
        guard !isSafeUnquoted else { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
