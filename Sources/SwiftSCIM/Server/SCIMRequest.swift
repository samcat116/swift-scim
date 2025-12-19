import Foundation

/// HTTP methods supported by SCIM
public enum SCIMHTTPMethod: String, Sendable {
    case GET
    case POST
    case PUT
    case PATCH
    case DELETE
}

/// Framework-agnostic HTTP request representation for SCIM operations
public struct SCIMRequest: Sendable {
    /// HTTP method
    public let method: SCIMHTTPMethod

    /// Request path (e.g., "/Users/123")
    public let path: String

    /// Query parameters
    public let queryParameters: [String: String]

    /// Request headers
    public let headers: [String: String]

    /// Request body as raw Data
    public let body: Data?

    /// Content-Type header value
    public var contentType: String? {
        headers["Content-Type"] ?? headers["content-type"]
    }

    /// Accept header value
    public var accept: String? {
        headers["Accept"] ?? headers["accept"]
    }

    /// Authorization header value
    public var authorization: String? {
        headers["Authorization"] ?? headers["authorization"]
    }

    /// If-Match header value (for ETags)
    public var ifMatch: String? {
        headers["If-Match"] ?? headers["if-match"]
    }

    /// If-None-Match header value (for ETags)
    public var ifNoneMatch: String? {
        headers["If-None-Match"] ?? headers["if-none-match"]
    }

    public init(
        method: SCIMHTTPMethod,
        path: String,
        queryParameters: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.path = path
        self.queryParameters = queryParameters
        self.headers = headers
        self.body = body
    }

    /// Decode the request body as a specific type
    public func decodeBody<T: Decodable>(as type: T.Type, using decoder: JSONDecoder = SCIMRequest.defaultDecoder) throws -> T {
        guard let body = body else {
            throw SCIMServerError.badRequest(detail: "Request body is required", scimType: .invalidSyntax)
        }
        do {
            return try decoder.decode(type, from: body)
        } catch {
            throw SCIMServerError.badRequest(detail: "Invalid request body: \(error.localizedDescription)", scimType: .invalidSyntax)
        }
    }

    /// Default JSON decoder configured for SCIM
    public static let defaultDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Path Parsing

extension SCIMRequest {
    /// Parsed path components
    public struct ParsedPath: Sendable {
        /// The resource endpoint (e.g., "Users", "Groups")
        public let endpoint: String?

        /// The resource ID if present
        public let resourceId: String?

        /// Whether this is a search endpoint (/.search)
        public let isSearch: Bool

        /// Remaining path segments after endpoint and ID
        public let remainingSegments: [String]
    }

    /// Parse the request path into components
    public func parsePath() -> ParsedPath {
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let segments = trimmedPath.split(separator: "/").map(String.init)

        guard !segments.isEmpty else {
            return ParsedPath(endpoint: nil, resourceId: nil, isSearch: false, remainingSegments: [])
        }

        // Check for /.search at the end
        if segments.last == ".search" {
            if segments.count == 1 {
                // Root search: /.search
                return ParsedPath(endpoint: nil, resourceId: nil, isSearch: true, remainingSegments: [])
            } else {
                // Resource search: /Users/.search
                return ParsedPath(
                    endpoint: segments[0],
                    resourceId: nil,
                    isSearch: true,
                    remainingSegments: Array(segments.dropFirst().dropLast())
                )
            }
        }

        let endpoint = segments[0]
        let resourceId = segments.count > 1 ? segments[1] : nil
        let remaining = segments.count > 2 ? Array(segments.dropFirst(2)) : []

        return ParsedPath(
            endpoint: endpoint,
            resourceId: resourceId,
            isSearch: false,
            remainingSegments: remaining
        )
    }
}
