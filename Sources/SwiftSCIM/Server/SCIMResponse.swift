import Foundation

/// Framework-agnostic HTTP response representation for SCIM operations
public struct SCIMResponse: Sendable {
    /// HTTP status code
    public let statusCode: Int

    /// Response headers
    public let headers: [String: String]

    /// Response body as raw Data
    public let body: Data?

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// Default JSON encoder configured for SCIM
    public static let defaultEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Default SCIM response headers
    public static let scimHeaders: [String: String] = [
        "Content-Type": "application/scim+json"
    ]
}

// MARK: - Convenience Factory Methods

extension SCIMResponse {
    /// Create a 200 OK response with a body
    public static func ok<T: Encodable>(_ resource: T, location: String? = nil, etag: String? = nil) throws -> SCIMResponse {
        let body = try defaultEncoder.encode(resource)
        var headers = scimHeaders
        if let location = location {
            headers["Location"] = location
        }
        if let etag = etag {
            headers["ETag"] = etag
        }
        return SCIMResponse(statusCode: 200, headers: headers, body: body)
    }

    /// Create a 200 OK response with raw body data
    public static func ok(_ body: Data, headers: [String: String] = scimHeaders) -> SCIMResponse {
        SCIMResponse(statusCode: 200, headers: headers, body: body)
    }

    /// Create a 201 Created response
    public static func created<T: Encodable>(_ resource: T, location: String, etag: String? = nil) throws -> SCIMResponse {
        let body = try defaultEncoder.encode(resource)
        var headers = scimHeaders
        headers["Location"] = location
        if let etag = etag {
            headers["ETag"] = etag
        }
        return SCIMResponse(statusCode: 201, headers: headers, body: body)
    }

    /// Create a 204 No Content response
    public static func noContent() -> SCIMResponse {
        SCIMResponse(statusCode: 204, headers: [:], body: nil)
    }

    /// Create a 304 Not Modified response
    public static func notModified() -> SCIMResponse {
        SCIMResponse(statusCode: 304, headers: [:], body: nil)
    }

    /// Create an error response from a SCIMServerError
    public static func error(_ error: SCIMServerError) -> SCIMResponse {
        let errorResponse = error.errorResponse
        do {
            let body = try defaultEncoder.encode(errorResponse)
            return SCIMResponse(statusCode: error.statusCode, headers: scimHeaders, body: body)
        } catch {
            // Fallback if encoding fails
            return SCIMResponse(statusCode: 500, headers: scimHeaders, body: nil)
        }
    }

    /// Create an error response from a SCIMErrorResponse
    public static func error(_ errorResponse: SCIMErrorResponse, statusCode: Int) throws -> SCIMResponse {
        let body = try defaultEncoder.encode(errorResponse)
        return SCIMResponse(statusCode: statusCode, headers: scimHeaders, body: body)
    }

    /// Create a 400 Bad Request response
    public static func badRequest(detail: String, scimType: SCIMErrorType? = nil) -> SCIMResponse {
        error(.badRequest(detail: detail, scimType: scimType))
    }

    /// Create a 401 Unauthorized response
    public static func unauthorized(detail: String? = nil) -> SCIMResponse {
        error(.unauthorized(detail: detail))
    }

    /// Create a 403 Forbidden response
    public static func forbidden(detail: String? = nil) -> SCIMResponse {
        error(.forbidden(detail: detail))
    }

    /// Create a 404 Not Found response
    public static func notFound(resourceType: String, id: String) -> SCIMResponse {
        error(.notFound(resourceType: resourceType, id: id))
    }

    /// Create a 409 Conflict response
    public static func conflict(detail: String) -> SCIMResponse {
        error(.conflict(detail: detail))
    }

    /// Create a 500 Internal Server Error response
    public static func internalServerError(detail: String) -> SCIMResponse {
        error(.internalError(detail: detail))
    }
}
