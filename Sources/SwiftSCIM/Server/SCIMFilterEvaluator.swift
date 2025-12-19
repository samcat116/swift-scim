import Foundation

/// Evaluates SCIM filter expressions against resources (RFC 7644 Section 3.4.2.2)
///
/// Supports all SCIM filter operators:
/// - eq: equal (case-insensitive for strings)
/// - ne: not equal
/// - co: contains
/// - sw: starts with
/// - ew: ends with
/// - gt: greater than
/// - ge: greater than or equal
/// - lt: less than
/// - le: less than or equal
/// - pr: present (has value)
///
/// Example:
/// ```swift
/// let filter = try SCIMFilterParser.parse("userName eq \"john\" and active eq true")
/// let matches = try SCIMFilterEvaluator.evaluate(filter, against: user)
/// ```
public struct SCIMFilterEvaluator {
    /// Evaluate a filter against a resource
    /// - Parameters:
    ///   - filter: The filter expression
    ///   - resource: The resource to evaluate
    /// - Returns: true if the resource matches the filter
    public static func evaluate<R: SCIMResource>(_ filter: SCIMFilterExpression, against resource: R) throws -> Bool {
        // Convert resource to dictionary for evaluation
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(resource)
        guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        return try evaluateExpression(filter, against: dictionary)
    }

    /// Filter a collection of resources
    /// - Parameters:
    ///   - resources: The resources to filter
    ///   - filter: The filter expression
    /// - Returns: Resources matching the filter
    public static func filter<R: SCIMResource>(_ resources: [R], with filter: SCIMFilterExpression) throws -> [R] {
        try resources.filter { resource in
            try evaluate(filter, against: resource)
        }
    }

    /// Evaluate an expression against a dictionary
    private static func evaluateExpression(_ expr: SCIMFilterExpression, against dictionary: [String: Any]) throws -> Bool {
        switch expr {
        case .empty:
            return true

        case .attribute(let attrPath, let op, let value):
            return try evaluateAttribute(attrPath: attrPath, op: op, value: value, in: dictionary)

        case .present(let attrPath):
            return hasValue(atPath: attrPath, in: dictionary)

        case .logical(let logicalOp, let left, let right):
            let leftResult = try evaluateExpression(left, against: dictionary)
            let rightResult = try evaluateExpression(right, against: dictionary)
            switch logicalOp {
            case .and:
                return leftResult && rightResult
            case .or:
                return leftResult || rightResult
            case .not:
                // Not is typically unary, but handle here for completeness
                return !leftResult
            }

        case .not(let inner):
            return try !evaluateExpression(inner, against: dictionary)

        case .group(let inner):
            return try evaluateExpression(inner, against: dictionary)
        }
    }

    /// Evaluate an attribute comparison
    private static func evaluateAttribute(attrPath: String, op: SCIMFilterOperator, value: String, in dictionary: [String: Any]) throws -> Bool {
        // Handle value path expressions like emails[type eq "work"].value
        if attrPath.contains("[") {
            return try evaluateValuePath(attrPath: attrPath, op: op, value: value, in: dictionary)
        }

        // Navigate to the attribute value
        let attrValue = navigateToValue(path: attrPath, in: dictionary)
        return compareValue(attrValue, op: op, filterValue: value)
    }

    /// Evaluate a value path expression (e.g., emails[type eq "work"].value)
    private static func evaluateValuePath(attrPath: String, op: SCIMFilterOperator, value: String, in dictionary: [String: Any]) throws -> Bool {
        // Parse the value path
        guard let bracketStart = attrPath.firstIndex(of: "["),
              let bracketEnd = attrPath.firstIndex(of: "]") else {
            return false
        }

        let arrayAttr = String(attrPath[..<bracketStart])
        let filterPart = String(attrPath[attrPath.index(after: bracketStart)..<bracketEnd])
        let remainingPath = attrPath.index(after: bracketEnd) < attrPath.endIndex
            ? String(attrPath[attrPath.index(after: bracketEnd)...]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            : nil

        // Get the array
        guard let array = dictionary[arrayAttr] as? [[String: Any]] else {
            return false
        }

        // Parse the inner filter
        let innerFilter = try SCIMFilterParser.parse(filterPart)

        // Find matching elements and evaluate
        for element in array {
            if try evaluateExpression(innerFilter, against: element) {
                // Element matches the filter
                if let remaining = remainingPath, !remaining.isEmpty {
                    // Navigate to the sub-attribute and compare
                    let subValue = navigateToValue(path: remaining, in: element)
                    if compareValue(subValue, op: op, filterValue: value) {
                        return true
                    }
                } else {
                    // Compare the entire element (shouldn't happen in practice)
                    return true
                }
            }
        }

        return false
    }

    /// Navigate to a value using a dot-separated path
    private static func navigateToValue(path: String, in dictionary: [String: Any]) -> Any? {
        let components = path.split(separator: ".").map(String.init)
        var current: Any = dictionary

        for component in components {
            if let dict = current as? [String: Any], let value = dict[component] {
                current = value
            } else {
                return nil
            }
        }

        return current
    }

    /// Check if a value exists at the given path
    private static func hasValue(atPath path: String, in dictionary: [String: Any]) -> Bool {
        // Handle value path expressions
        if path.contains("[") {
            // For value paths, check if any element matches
            guard let bracketStart = path.firstIndex(of: "["),
                  let bracketEnd = path.firstIndex(of: "]") else {
                return false
            }

            let arrayAttr = String(path[..<bracketStart])
            guard let array = dictionary[arrayAttr] as? [[String: Any]], !array.isEmpty else {
                return false
            }

            let remainingPath = path.index(after: bracketEnd) < path.endIndex
                ? String(path[path.index(after: bracketEnd)...]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                : nil

            if let remaining = remainingPath, !remaining.isEmpty {
                return array.contains { element in
                    navigateToValue(path: remaining, in: element) != nil
                }
            }
            return true
        }

        let value = navigateToValue(path: path, in: dictionary)
        if value == nil { return false }
        if value is NSNull { return false }
        if let arr = value as? [Any] { return !arr.isEmpty }
        return true
    }

    /// Compare a value using the specified operator
    private static func compareValue(_ attrValue: Any?, op: SCIMFilterOperator, filterValue: String) -> Bool {
        guard let attrValue = attrValue else {
            return false
        }

        // Handle arrays - check if any element matches
        if let array = attrValue as? [Any] {
            return array.contains { element in
                compareValue(element, op: op, filterValue: filterValue)
            }
        }

        // Handle multi-valued attributes with .value
        if let dict = attrValue as? [String: Any], let value = dict["value"] {
            return compareValue(value, op: op, filterValue: filterValue)
        }

        switch op {
        case .equal:
            return isEqual(attrValue, filterValue)
        case .notEqual:
            return !isEqual(attrValue, filterValue)
        case .contains:
            return stringValue(attrValue)?.lowercased().contains(filterValue.lowercased()) ?? false
        case .startsWith:
            return stringValue(attrValue)?.lowercased().hasPrefix(filterValue.lowercased()) ?? false
        case .endsWith:
            return stringValue(attrValue)?.lowercased().hasSuffix(filterValue.lowercased()) ?? false
        case .greaterThan:
            return compare(attrValue, filterValue) == .orderedDescending
        case .greaterThanOrEqual:
            let result = compare(attrValue, filterValue)
            return result == .orderedDescending || result == .orderedSame
        case .lessThan:
            return compare(attrValue, filterValue) == .orderedAscending
        case .lessThanOrEqual:
            let result = compare(attrValue, filterValue)
            return result == .orderedAscending || result == .orderedSame
        case .present:
            return true // Already handled separately
        }
    }

    /// Check equality (case-insensitive for strings)
    private static func isEqual(_ attrValue: Any, _ filterValue: String) -> Bool {
        if let s = stringValue(attrValue) {
            return s.lowercased() == filterValue.lowercased()
        }
        if let b = attrValue as? Bool {
            return String(b).lowercased() == filterValue.lowercased()
        }
        if let n = attrValue as? Double {
            if let filterNum = Double(filterValue) {
                return n == filterNum
            }
        }
        if let n = attrValue as? Int {
            if let filterNum = Int(filterValue) {
                return n == filterNum
            }
        }
        return false
    }

    /// Get string value from any type
    private static func stringValue(_ value: Any) -> String? {
        if let s = value as? String {
            return s
        }
        if let n = value as? Double {
            return String(n)
        }
        if let n = value as? Int {
            return String(n)
        }
        if let b = value as? Bool {
            return String(b)
        }
        return nil
    }

    /// Compare values
    private static func compare(_ attrValue: Any, _ filterValue: String) -> ComparisonResult {
        if let s = stringValue(attrValue) {
            return s.compare(filterValue, options: .caseInsensitive)
        }
        if let n = attrValue as? Double, let fn = Double(filterValue) {
            if n < fn { return .orderedAscending }
            if n > fn { return .orderedDescending }
            return .orderedSame
        }
        if let n = attrValue as? Int, let fn = Int(filterValue) {
            if n < fn { return .orderedAscending }
            if n > fn { return .orderedDescending }
            return .orderedSame
        }
        return .orderedSame
    }
}
