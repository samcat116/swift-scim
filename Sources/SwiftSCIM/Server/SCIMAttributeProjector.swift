import Foundation

/// Projects (includes/excludes) attributes from SCIM resources (RFC 7644 Section 3.4.2.5)
///
/// SCIM supports two attribute filtering mechanisms:
/// - `attributes`: Only include specified attributes
/// - `excludedAttributes`: Include all attributes except those specified
///
/// These are mutually exclusive; if both are specified, `attributes` takes precedence.
///
/// Example:
/// ```swift
/// // Include only specific attributes
/// let projected = try SCIMAttributeProjector.project(
///     user,
///     attributes: ["userName", "name.familyName", "emails"]
/// )
///
/// // Exclude specific attributes
/// let projected = try SCIMAttributeProjector.project(
///     user,
///     excludedAttributes: ["password", "phoneNumbers"]
/// )
/// ```
public struct SCIMAttributeProjector {
    /// Project a resource to include only specified attributes
    /// - Parameters:
    ///   - resource: The resource to project
    ///   - attributes: Attributes to include (supports dot notation)
    /// - Returns: The projected resource
    public static func include<R: SCIMResource>(attributes: [String], in resource: R) throws -> R {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(resource)

        guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SCIMServerError.internalError(detail: "Failed to serialize resource")
        }

        // Always include required SCIM attributes
        let requiredAttributes = ["schemas", "id", "meta"]

        let projected = projectInclude(dictionary: dictionary, attributes: attributes, requiredAttributes: requiredAttributes)

        let modifiedData = try JSONSerialization.data(withJSONObject: projected)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(R.self, from: modifiedData)
    }

    /// Project a resource to exclude specified attributes
    /// - Parameters:
    ///   - resource: The resource to project
    ///   - excludedAttributes: Attributes to exclude (supports dot notation)
    /// - Returns: The projected resource
    public static func exclude<R: SCIMResource>(attributes excludedAttributes: [String], from resource: R) throws -> R {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(resource)

        guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SCIMServerError.internalError(detail: "Failed to serialize resource")
        }

        // Never exclude required SCIM attributes
        let protectedAttributes = ["schemas", "id"]

        let projected = projectExclude(dictionary: dictionary, excludedAttributes: excludedAttributes, protectedAttributes: protectedAttributes)

        let modifiedData = try JSONSerialization.data(withJSONObject: projected)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(R.self, from: modifiedData)
    }

    /// Apply projection based on query parameters
    /// - Parameters:
    ///   - resource: The resource to project
    ///   - query: Server query with attributes/excludedAttributes
    /// - Returns: The projected resource
    public static func project<R: SCIMResource>(_ resource: R, using query: SCIMServerQuery) throws -> R {
        if let attributes = query.attributes, !attributes.isEmpty {
            return try include(attributes: attributes, in: resource)
        } else if let excludedAttributes = query.excludedAttributes, !excludedAttributes.isEmpty {
            return try exclude(attributes: excludedAttributes, from: resource)
        }
        return resource
    }

    // MARK: - Private Helpers

    private static func projectInclude(dictionary: [String: Any], attributes: [String], requiredAttributes: [String]) -> [String: Any] {
        var result: [String: Any] = [:]

        // Parse attributes into a set of top-level keys and nested paths
        var topLevelAttrs = Set<String>()
        var nestedPaths: [String: Set<String>] = [:]

        for attr in attributes {
            let components = attr.split(separator: ".").map(String.init)
            if components.count == 1 {
                topLevelAttrs.insert(components[0])
            } else {
                let topLevel = components[0]
                let remaining = components.dropFirst().joined(separator: ".")
                if nestedPaths[topLevel] == nil {
                    nestedPaths[topLevel] = []
                }
                nestedPaths[topLevel]?.insert(remaining)
            }
        }

        // Always include required attributes
        for attr in requiredAttributes {
            if let value = dictionary[attr] {
                result[attr] = value
            }
        }

        // Include requested top-level attributes
        for attr in topLevelAttrs {
            if let value = dictionary[attr] {
                result[attr] = value
            }
        }

        // Handle nested paths
        for (topLevel, subPaths) in nestedPaths {
            if let value = dictionary[topLevel] as? [String: Any] {
                let projected = projectNestedInclude(dictionary: value, paths: Array(subPaths))
                result[topLevel] = projected
            }
        }

        return result
    }

    private static func projectNestedInclude(dictionary: [String: Any], paths: [String]) -> [String: Any] {
        var result: [String: Any] = [:]

        for path in paths {
            let components = path.split(separator: ".").map(String.init)
            if components.count == 1 {
                if let value = dictionary[components[0]] {
                    result[components[0]] = value
                }
            } else {
                let topLevel = components[0]
                if let nested = dictionary[topLevel] as? [String: Any] {
                    let remaining = components.dropFirst().joined(separator: ".")
                    let projected = projectNestedInclude(dictionary: nested, paths: [remaining])
                    if result[topLevel] == nil {
                        result[topLevel] = projected
                    } else if var existing = result[topLevel] as? [String: Any] {
                        existing.merge(projected) { _, new in new }
                        result[topLevel] = existing
                    }
                }
            }
        }

        return result
    }

    private static func projectExclude(dictionary: [String: Any], excludedAttributes: [String], protectedAttributes: [String]) -> [String: Any] {
        var result = dictionary

        for attr in excludedAttributes {
            // Don't exclude protected attributes
            if protectedAttributes.contains(attr.split(separator: ".").first.map(String.init) ?? attr) {
                continue
            }

            let components = attr.split(separator: ".").map(String.init)

            if components.count == 1 {
                result.removeValue(forKey: attr)
            } else {
                // Navigate and remove nested attribute
                removeNestedAttribute(path: components, from: &result)
            }
        }

        return result
    }

    private static func removeNestedAttribute(path: [String], from dictionary: inout [String: Any]) {
        guard !path.isEmpty else { return }

        if path.count == 1 {
            dictionary.removeValue(forKey: path[0])
        } else {
            let key = path[0]
            if var nested = dictionary[key] as? [String: Any] {
                removeNestedAttribute(path: Array(path.dropFirst()), from: &nested)
                dictionary[key] = nested
            }
        }
    }
}
