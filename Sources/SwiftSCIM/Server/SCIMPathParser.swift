import Foundation

/// Parses SCIM attribute path expressions (RFC 7644 Section 3.5.2)
///
/// SCIM paths support:
/// - Simple attributes: `userName`, `displayName`
/// - Nested attributes: `name.familyName`, `name.givenName`
/// - Indexed attributes with filter: `emails[type eq "work"]`
/// - Nested within indexed: `emails[type eq "work"].value`
///
/// Example paths:
/// - `userName`
/// - `name.familyName`
/// - `emails[type eq "work"].value`
/// - `addresses[type eq "home"]`
public struct SCIMPathParser {
    /// A parsed SCIM path
    public struct ParsedPath: Sendable, Equatable {
        /// The path segments
        public let segments: [PathSegment]

        /// Whether this path is empty
        public var isEmpty: Bool { segments.isEmpty }

        /// The root attribute name
        public var rootAttribute: String? {
            guard let first = segments.first else { return nil }
            switch first {
            case .attribute(let name), .indexedAttribute(let name, _):
                return name
            case .subAttribute:
                return nil
            }
        }
    }

    /// A segment of a SCIM path
    public enum PathSegment: Sendable, Equatable {
        /// A simple attribute: `userName`
        case attribute(String)

        /// An indexed attribute with filter: `emails[type eq "work"]`
        case indexedAttribute(String, filter: String)

        /// A sub-attribute: `.value` (the part after a dot)
        case subAttribute(String)
    }

    /// Parse a SCIM path string
    /// - Parameter path: The path string to parse
    /// - Returns: The parsed path
    /// - Throws: `SCIMServerError.invalidPath` if the path is malformed
    public static func parse(_ path: String) throws -> ParsedPath {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return ParsedPath(segments: [])
        }

        var segments: [PathSegment] = []
        var remaining = trimmed[...]
        var isFirst = true

        while !remaining.isEmpty {
            // If not first segment, expect a dot
            if !isFirst {
                if remaining.first == "." {
                    remaining = remaining.dropFirst()
                } else {
                    throw SCIMServerError.invalidPath(detail: "Expected '.' in path: \(path)")
                }
            }
            isFirst = false

            // Parse attribute name (until '[' or '.' or end)
            var attributeName = ""
            while let char = remaining.first, char != "[" && char != "." {
                attributeName.append(char)
                remaining = remaining.dropFirst()
            }

            guard !attributeName.isEmpty else {
                throw SCIMServerError.invalidPath(detail: "Empty attribute name in path: \(path)")
            }

            // Check for filter
            if remaining.first == "[" {
                // Parse filter
                remaining = remaining.dropFirst() // consume '['
                var filterContent = ""
                var bracketDepth = 1

                while !remaining.isEmpty && bracketDepth > 0 {
                    let char = remaining.removeFirst()
                    if char == "[" {
                        bracketDepth += 1
                        filterContent.append(char)
                    } else if char == "]" {
                        bracketDepth -= 1
                        if bracketDepth > 0 {
                            filterContent.append(char)
                        }
                    } else {
                        filterContent.append(char)
                    }
                }

                if bracketDepth != 0 {
                    throw SCIMServerError.invalidPath(detail: "Unmatched bracket in path: \(path)")
                }

                if segments.isEmpty {
                    segments.append(.indexedAttribute(attributeName, filter: filterContent))
                } else {
                    segments.append(.subAttribute(attributeName))
                    // Indexed sub-attributes aren't standard but handle gracefully
                }
            } else {
                if segments.isEmpty {
                    segments.append(.attribute(attributeName))
                } else {
                    segments.append(.subAttribute(attributeName))
                }
            }
        }

        return ParsedPath(segments: segments)
    }
}

// MARK: - Path Navigation

extension SCIMPathParser.ParsedPath {
    /// Navigate to a value in a dictionary using this path
    /// - Parameter dictionary: The dictionary to navigate
    /// - Returns: The value at the path, or nil if not found
    public func navigate(in dictionary: [String: Any]) -> Any? {
        var current: Any = dictionary

        for segment in segments {
            switch segment {
            case .attribute(let name), .subAttribute(let name):
                guard let dict = current as? [String: Any],
                      let value = dict[name] else {
                    return nil
                }
                current = value

            case .indexedAttribute(let name, let filter):
                guard let dict = current as? [String: Any],
                      let array = dict[name] as? [[String: Any]] else {
                    return nil
                }
                // Find matching element
                guard let match = findMatchingElement(in: array, filter: filter) else {
                    return nil
                }
                current = match
            }
        }

        return current
    }

    /// Find an element in an array matching a simple filter
    private func findMatchingElement(in array: [[String: Any]], filter: String) -> [String: Any]? {
        // Parse simple filter: "type eq \"work\""
        let parts = filter.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
        guard parts.count >= 3 else { return nil }

        let attribute = String(parts[0])
        let op = String(parts[1]).lowercased()
        var value = String(parts[2])

        // Remove quotes
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }

        guard op == "eq" else { return nil } // Only support eq for now

        return array.first { element in
            guard let attrValue = element[attribute] else { return false }
            if let stringValue = attrValue as? String {
                return stringValue == value
            }
            return false
        }
    }

    /// Set a value in a dictionary at this path
    /// - Parameters:
    ///   - value: The value to set
    ///   - dictionary: The dictionary to modify
    /// - Returns: The modified dictionary
    /// - Throws: `SCIMServerError.noTarget` if the path doesn't exist
    public func setValue(_ value: Any, in dictionary: inout [String: Any]) throws {
        guard !segments.isEmpty else {
            throw SCIMServerError.invalidPath(detail: "Cannot set value at empty path")
        }

        if segments.count == 1 {
            // Direct attribute
            switch segments[0] {
            case .attribute(let name), .subAttribute(let name):
                dictionary[name] = value
            case .indexedAttribute:
                throw SCIMServerError.invalidPath(detail: "Cannot set entire indexed attribute")
            }
        } else {
            // Navigate to parent and set
            try setNestedValue(value, in: &dictionary, segments: segments[...])
        }
    }

    private func setNestedValue(_ value: Any, in dictionary: inout [String: Any], segments: ArraySlice<SCIMPathParser.PathSegment>) throws {
        guard let first = segments.first else { return }
        let remaining = segments.dropFirst()

        switch first {
        case .attribute(let name), .subAttribute(let name):
            if remaining.isEmpty {
                dictionary[name] = value
            } else {
                var nested = dictionary[name] as? [String: Any] ?? [:]
                try setNestedValue(value, in: &nested, segments: remaining)
                dictionary[name] = nested
            }

        case .indexedAttribute(let name, let filter):
            guard var array = dictionary[name] as? [[String: Any]] else {
                throw SCIMServerError.noTarget(detail: "No array at path: \(name)")
            }

            // Find and update matching element
            let parts = filter.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
            guard parts.count >= 3 else {
                throw SCIMServerError.invalidPath(detail: "Invalid filter: \(filter)")
            }

            let attribute = String(parts[0])
            var filterValue = String(parts[2])
            if filterValue.hasPrefix("\"") && filterValue.hasSuffix("\"") {
                filterValue = String(filterValue.dropFirst().dropLast())
            }

            var found = false
            for i in array.indices {
                if let attrValue = array[i][attribute] as? String, attrValue == filterValue {
                    if remaining.isEmpty {
                        if let dictValue = value as? [String: Any] {
                            array[i].merge(dictValue) { _, new in new }
                        }
                    } else {
                        try setNestedValue(value, in: &array[i], segments: remaining)
                    }
                    found = true
                    break
                }
            }

            if !found {
                throw SCIMServerError.noTarget(detail: "No matching element for filter: \(filter)")
            }

            dictionary[name] = array
        }
    }

    /// Remove a value from a dictionary at this path
    /// - Parameter dictionary: The dictionary to modify
    /// - Returns: The modified dictionary
    public func removeValue(from dictionary: inout [String: Any]) throws {
        guard !segments.isEmpty else {
            throw SCIMServerError.invalidPath(detail: "Cannot remove value at empty path")
        }

        if segments.count == 1 {
            switch segments[0] {
            case .attribute(let name), .subAttribute(let name):
                dictionary.removeValue(forKey: name)
            case .indexedAttribute(let name, let filter):
                // Remove matching element from array
                guard var array = dictionary[name] as? [[String: Any]] else { return }
                let parts = filter.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
                guard parts.count >= 3 else { return }
                let attribute = String(parts[0])
                var filterValue = String(parts[2])
                if filterValue.hasPrefix("\"") && filterValue.hasSuffix("\"") {
                    filterValue = String(filterValue.dropFirst().dropLast())
                }
                array.removeAll { element in
                    guard let attrValue = element[attribute] as? String else { return false }
                    return attrValue == filterValue
                }
                dictionary[name] = array
            }
        } else {
            try removeNestedValue(from: &dictionary, segments: segments[...])
        }
    }

    private func removeNestedValue(from dictionary: inout [String: Any], segments: ArraySlice<SCIMPathParser.PathSegment>) throws {
        guard let first = segments.first else { return }
        let remaining = segments.dropFirst()

        switch first {
        case .attribute(let name), .subAttribute(let name):
            if remaining.isEmpty {
                dictionary.removeValue(forKey: name)
            } else {
                guard var nested = dictionary[name] as? [String: Any] else { return }
                try removeNestedValue(from: &nested, segments: remaining)
                dictionary[name] = nested
            }

        case .indexedAttribute(let name, let filter):
            guard var array = dictionary[name] as? [[String: Any]] else { return }

            let parts = filter.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
            guard parts.count >= 3 else { return }
            let attribute = String(parts[0])
            var filterValue = String(parts[2])
            if filterValue.hasPrefix("\"") && filterValue.hasSuffix("\"") {
                filterValue = String(filterValue.dropFirst().dropLast())
            }

            for i in array.indices {
                if let attrValue = array[i][attribute] as? String, attrValue == filterValue {
                    if remaining.isEmpty {
                        array.remove(at: i)
                    } else {
                        try removeNestedValue(from: &array[i], segments: remaining)
                    }
                    break
                }
            }

            dictionary[name] = array
        }
    }
}
