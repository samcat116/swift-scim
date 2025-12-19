import Foundation

/// Query parameters for server-side SCIM operations
public struct SCIMServerQuery: Sendable {
    /// Raw filter string (unparsed)
    public let filterString: String?

    /// Parsed filter expression (nil means no filter)
    public let filter: SCIMFilterExpression?

    /// Attributes to include in response
    public let attributes: [String]?

    /// Attributes to exclude from response
    public let excludedAttributes: [String]?

    /// Sort attribute
    public let sortBy: String?

    /// Sort direction
    public let sortOrder: SortOrder

    /// Starting index (1-based per SCIM spec)
    public let startIndex: Int

    /// Maximum results to return
    public let count: Int

    /// Sort order options
    public enum SortOrder: String, Sendable {
        case ascending
        case descending
    }

    public init(
        filterString: String? = nil,
        filter: SCIMFilterExpression? = nil,
        attributes: [String]? = nil,
        excludedAttributes: [String]? = nil,
        sortBy: String? = nil,
        sortOrder: SortOrder = .ascending,
        startIndex: Int = 1,
        count: Int = 100
    ) {
        self.filterString = filterString
        self.filter = filter
        self.attributes = attributes
        self.excludedAttributes = excludedAttributes
        self.sortBy = sortBy
        self.sortOrder = sortOrder
        self.startIndex = startIndex
        self.count = count
    }

    /// Initialize from raw query parameters
    /// - Parameters:
    ///   - parameters: Dictionary of query parameter strings
    ///   - maxResults: Maximum allowed results (server configuration)
    ///   - defaultCount: Default page size if not specified
    public init(
        from parameters: [String: String],
        maxResults: Int = 1000,
        defaultCount: Int = 100
    ) throws {
        self.filterString = parameters["filter"]

        // Parse filter if present
        if let filterString = parameters["filter"], !filterString.isEmpty {
            self.filter = try SCIMFilterParser.parse(filterString)
        } else {
            self.filter = nil
        }

        // Parse attributes
        if let attrs = parameters["attributes"], !attrs.isEmpty {
            self.attributes = attrs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            self.attributes = nil
        }

        // Parse excluded attributes
        if let excludedAttrs = parameters["excludedAttributes"], !excludedAttrs.isEmpty {
            self.excludedAttributes = excludedAttrs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            self.excludedAttributes = nil
        }

        // Parse sorting
        self.sortBy = parameters["sortBy"]

        if let sortOrderStr = parameters["sortOrder"]?.lowercased() {
            self.sortOrder = sortOrderStr == "descending" ? .descending : .ascending
        } else {
            self.sortOrder = .ascending
        }

        // Parse pagination
        if let startIndexStr = parameters["startIndex"], let startIndex = Int(startIndexStr) {
            self.startIndex = max(1, startIndex)
        } else {
            self.startIndex = 1
        }

        if let countStr = parameters["count"], let count = Int(countStr) {
            self.count = min(max(1, count), maxResults)
        } else {
            self.count = min(defaultCount, maxResults)
        }
    }

    /// The zero-based offset for array slicing
    public var offset: Int {
        max(0, startIndex - 1)
    }
}
