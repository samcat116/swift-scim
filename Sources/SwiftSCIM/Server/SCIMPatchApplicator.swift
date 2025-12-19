import Foundation

/// Applies SCIM PATCH operations to resources (RFC 7644 Section 3.5.2)
///
/// SCIM PATCH supports three operations:
/// - `add`: Add a new value or values to an attribute
/// - `remove`: Remove a value or attribute
/// - `replace`: Replace the value of an attribute
///
/// Example:
/// ```swift
/// let operations = [
///     SCIMPatchOperation.replace(path: "displayName", stringValue: "New Name"),
///     SCIMPatchOperation.add(path: "emails", value: .array([
///         .object(["value": .string("new@example.com"), "type": .string("work")])
///     ])),
///     SCIMPatchOperation.remove(path: "phoneNumbers")
/// ]
/// let patched = try SCIMPatchApplicator.apply(operations, to: user)
/// ```
public struct SCIMPatchApplicator {
    /// Apply PATCH operations to a resource
    /// - Parameters:
    ///   - operations: The operations to apply
    ///   - resource: The resource to modify
    /// - Returns: The modified resource
    /// - Throws: `SCIMServerError` if any operation fails
    public static func apply<R: SCIMResource>(_ operations: [SCIMPatchOperation], to resource: R) throws -> R {
        // Encode resource to dictionary
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(resource)

        guard var dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SCIMServerError.internalError(detail: "Failed to serialize resource")
        }

        // Apply each operation
        for operation in operations {
            try applyOperation(operation, to: &dictionary)
        }

        // Decode back to resource type
        let modifiedData = try JSONSerialization.data(withJSONObject: dictionary)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(R.self, from: modifiedData)
    }

    /// Apply a single operation to a dictionary
    private static func applyOperation(_ operation: SCIMPatchOperation, to dictionary: inout [String: Any]) throws {
        switch operation.op {
        case .add:
            try applyAdd(path: operation.path, value: operation.value, to: &dictionary)
        case .remove:
            try applyRemove(path: operation.path, from: &dictionary)
        case .replace:
            try applyReplace(path: operation.path, value: operation.value, to: &dictionary)
        }
    }

    // MARK: - Add Operation

    private static func applyAdd(path: String?, value: SCIMPatchValue?, to dictionary: inout [String: Any]) throws {
        guard let value = value else {
            throw SCIMServerError.badRequest(detail: "Add operation requires a value", scimType: .invalidValue)
        }

        let jsonValue = value.toJSON()

        if let path = path, !path.isEmpty {
            // Add at specific path
            let parsedPath = try SCIMPathParser.parse(path)

            if let existing = parsedPath.navigate(in: dictionary) {
                // If target is array, append
                if var existingArray = existing as? [Any] {
                    if let newArray = jsonValue as? [Any] {
                        existingArray.append(contentsOf: newArray)
                    } else {
                        existingArray.append(jsonValue)
                    }
                    try parsedPath.setValue(existingArray, in: &dictionary)
                } else {
                    // Replace existing value
                    try parsedPath.setValue(jsonValue, in: &dictionary)
                }
            } else {
                // Create new value at path
                try parsedPath.setValue(jsonValue, in: &dictionary)
            }
        } else {
            // No path - merge object into resource
            guard let objectValue = jsonValue as? [String: Any] else {
                throw SCIMServerError.badRequest(detail: "Add operation without path requires an object value", scimType: .invalidValue)
            }
            for (key, val) in objectValue {
                if let existingArray = dictionary[key] as? [Any], let newArray = val as? [Any] {
                    dictionary[key] = existingArray + newArray
                } else {
                    dictionary[key] = val
                }
            }
        }
    }

    // MARK: - Remove Operation

    private static func applyRemove(path: String?, from dictionary: inout [String: Any]) throws {
        guard let path = path, !path.isEmpty else {
            throw SCIMServerError.noTarget(detail: "Remove operation requires a path")
        }

        let parsedPath = try SCIMPathParser.parse(path)
        try parsedPath.removeValue(from: &dictionary)
    }

    // MARK: - Replace Operation

    private static func applyReplace(path: String?, value: SCIMPatchValue?, to dictionary: inout [String: Any]) throws {
        guard let value = value else {
            throw SCIMServerError.badRequest(detail: "Replace operation requires a value", scimType: .invalidValue)
        }

        let jsonValue = value.toJSON()

        if let path = path, !path.isEmpty {
            // Replace at specific path
            let parsedPath = try SCIMPathParser.parse(path)

            // Verify target exists (optional per spec, but good practice)
            if parsedPath.navigate(in: dictionary) == nil {
                // For replace, we can create if not exists (some implementations do this)
                // Or throw noTarget - following strict interpretation
                // We'll be lenient and create it
            }

            try parsedPath.setValue(jsonValue, in: &dictionary)
        } else {
            // No path - replace entire resource (merge)
            guard let objectValue = jsonValue as? [String: Any] else {
                throw SCIMServerError.badRequest(detail: "Replace operation without path requires an object value", scimType: .invalidValue)
            }
            for (key, val) in objectValue {
                dictionary[key] = val
            }
        }
    }
}

// MARK: - SCIMPatchValue JSON Conversion

extension SCIMPatchValue {
    /// Convert to a JSON-compatible value
    func toJSON() -> Any {
        switch self {
        case .string(let s):
            return s
        case .number(let n):
            return n
        case .boolean(let b):
            return b
        case .null:
            return NSNull()
        case .array(let arr):
            return arr.map { $0.toJSON() }
        case .object(let obj):
            return obj.mapValues { $0.toJSON() }
        }
    }

    /// Create from a JSON-compatible value
    static func fromJSON(_ value: Any) -> SCIMPatchValue {
        if value is NSNull {
            return .null
        } else if let s = value as? String {
            return .string(s)
        } else if let n = value as? Double {
            return .number(n)
        } else if let n = value as? Int {
            return .number(Double(n))
        } else if let b = value as? Bool {
            return .boolean(b)
        } else if let arr = value as? [Any] {
            return .array(arr.map { fromJSON($0) })
        } else if let obj = value as? [String: Any] {
            return .object(obj.mapValues { fromJSON($0) })
        } else {
            return .null
        }
    }
}
