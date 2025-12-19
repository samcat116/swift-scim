import Foundation

/// Parses SCIM filter strings into filter expressions (RFC 7644 Section 3.4.2.2)
///
/// SCIM filter syntax supports:
/// - Attribute operators: eq, ne, co, sw, ew, gt, ge, lt, le, pr
/// - Logical operators: and, or, not
/// - Grouping with parentheses
/// - Value path filtering: `emails[type eq "work"]`
///
/// Example filters:
/// - `userName eq "john"`
/// - `name.familyName co "son"`
/// - `emails[type eq "work"].value ew "@example.com"`
/// - `active eq true and emails pr`
/// - `not (userName eq "admin")`
public struct SCIMFilterParser {
    /// Parse a filter string into an expression
    /// - Parameter filterString: The SCIM filter string
    /// - Returns: Parsed filter expression
    /// - Throws: `SCIMServerError.invalidFilter` if the filter is malformed
    public static func parse(_ filterString: String) throws -> SCIMFilterExpression {
        let trimmed = filterString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return .empty
        }

        var parser = FilterParser(input: trimmed)
        return try parser.parseExpression()
    }
}

// MARK: - Parser Implementation

private struct FilterParser {
    var input: Substring
    var position: String.Index

    init(input: String) {
        self.input = input[...]
        self.position = input.startIndex
    }

    mutating func parseExpression() throws -> SCIMFilterExpression {
        skipWhitespace()
        var left = try parsePrimary()

        while true {
            skipWhitespace()

            if matchKeyword("and") {
                skipWhitespace()
                let right = try parsePrimary()
                left = .logical(.and, left, right)
            } else if matchKeyword("or") {
                skipWhitespace()
                let right = try parsePrimary()
                left = .logical(.or, left, right)
            } else {
                break
            }
        }

        return left
    }

    mutating func parsePrimary() throws -> SCIMFilterExpression {
        skipWhitespace()

        // Check for NOT
        if matchKeyword("not") {
            skipWhitespace()
            let expr = try parsePrimary()
            return .not(expr)
        }

        // Check for grouped expression
        if peek() == "(" {
            advance()
            skipWhitespace()
            let expr = try parseExpression()
            skipWhitespace()
            guard peek() == ")" else {
                throw SCIMServerError.invalidFilter(detail: "Expected ')' in filter")
            }
            advance()
            return .group(expr)
        }

        // Parse attribute expression
        return try parseAttributeExpression()
    }

    mutating func parseAttributeExpression() throws -> SCIMFilterExpression {
        skipWhitespace()

        // Parse attribute path (may include value path like emails[type eq "work"].value)
        let attrPath = try parseAttributePath()

        skipWhitespace()

        // Check for 'pr' (present) operator - no value needed
        if matchKeyword("pr") {
            return .present(attrPath)
        }

        // Parse comparison operator
        guard let op = try parseOperator() else {
            throw SCIMServerError.invalidFilter(detail: "Expected operator after attribute: \(attrPath)")
        }

        skipWhitespace()

        // Parse value
        let value = try parseValue()

        return .attribute(attrPath, op, value)
    }

    mutating func parseAttributePath() throws -> String {
        var path = ""

        while let char = peek() {
            if char.isLetter || char.isNumber || char == "." || char == "_" || char == ":" || char == "$" {
                path.append(char)
                advance()
            } else if char == "[" {
                // Value path filter
                path.append(char)
                advance()
                var depth = 1
                while depth > 0, let c = peek() {
                    path.append(c)
                    advance()
                    if c == "[" { depth += 1 }
                    if c == "]" { depth -= 1 }
                }
            } else {
                break
            }
        }

        guard !path.isEmpty else {
            throw SCIMServerError.invalidFilter(detail: "Expected attribute path")
        }

        return path
    }

    mutating func parseOperator() throws -> SCIMFilterOperator? {
        skipWhitespace()

        for op in SCIMFilterOperator.allCases {
            if matchKeyword(op.rawValue) {
                return op
            }
        }

        return nil
    }

    mutating func parseValue() throws -> String {
        skipWhitespace()

        guard let firstChar = peek() else {
            throw SCIMServerError.invalidFilter(detail: "Expected value")
        }

        if firstChar == "\"" {
            // Quoted string
            advance() // consume opening quote
            var value = ""
            while let char = peek(), char != "\"" {
                if char == "\\" {
                    advance()
                    if let escaped = peek() {
                        value.append(escaped)
                        advance()
                    }
                } else {
                    value.append(char)
                    advance()
                }
            }
            guard peek() == "\"" else {
                throw SCIMServerError.invalidFilter(detail: "Unterminated string in filter")
            }
            advance() // consume closing quote
            return value
        } else {
            // Unquoted value (boolean, number, null)
            var value = ""
            while let char = peek(), !char.isWhitespace && char != ")" && char != "]" {
                value.append(char)
                advance()
            }
            return value
        }
    }

    // MARK: - Helper Methods

    func peek() -> Character? {
        guard position < input.endIndex else { return nil }
        return input[position]
    }

    mutating func advance() {
        if position < input.endIndex {
            position = input.index(after: position)
        }
    }

    mutating func skipWhitespace() {
        while let char = peek(), char.isWhitespace {
            advance()
        }
    }

    mutating func matchKeyword(_ keyword: String) -> Bool {
        let start = position
        var matched = true

        for char in keyword {
            guard let current = peek(), current.lowercased() == char.lowercased() else {
                matched = false
                break
            }
            advance()
        }

        // Ensure keyword is followed by whitespace or end/special char
        if matched {
            if let next = peek(), next.isLetter || next.isNumber {
                matched = false
            }
        }

        if !matched {
            position = start
        }

        return matched
    }
}
