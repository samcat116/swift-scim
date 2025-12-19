import Foundation

/// Server-side SCIM errors
public enum SCIMServerError: Error, Sendable {
    /// Resource not found (404)
    case notFound(resourceType: String, id: String)

    /// Resource already exists - uniqueness violation (409)
    case conflict(detail: String)

    /// Invalid request data (400)
    case badRequest(detail: String, scimType: SCIMErrorType?)

    /// Authentication required (401)
    case unauthorized(detail: String?)

    /// Permission denied (403)
    case forbidden(detail: String?)

    /// Invalid filter syntax (400)
    case invalidFilter(detail: String)

    /// Invalid PATCH path (400)
    case invalidPath(detail: String)

    /// No target for PATCH operation (400)
    case noTarget(detail: String)

    /// Mutability constraint violation (400)
    case mutability(detail: String)

    /// Too many results (400)
    case tooMany(maxResults: Int)

    /// Internal server error (500)
    case internalError(detail: String)

    /// HTTP status code for this error
    public var statusCode: Int {
        switch self {
        case .notFound:
            return 404
        case .conflict:
            return 409
        case .badRequest, .invalidFilter, .invalidPath, .noTarget, .mutability, .tooMany:
            return 400
        case .unauthorized:
            return 401
        case .forbidden:
            return 403
        case .internalError:
            return 500
        }
    }

    /// Convert to SCIM error response
    public var errorResponse: SCIMErrorResponse {
        switch self {
        case .notFound(let resourceType, let id):
            return SCIMErrorResponse(
                detail: "\(resourceType) with id '\(id)' not found",
                status: String(statusCode),
                scimType: nil
            )
        case .conflict(let detail):
            return SCIMErrorResponse(
                detail: detail,
                status: String(statusCode),
                scimType: SCIMErrorType.uniqueness.rawValue
            )
        case .badRequest(let detail, let scimType):
            return SCIMErrorResponse(
                detail: detail,
                status: String(statusCode),
                scimType: scimType?.rawValue
            )
        case .unauthorized(let detail):
            return SCIMErrorResponse(
                detail: detail ?? "Authentication required",
                status: String(statusCode),
                scimType: nil
            )
        case .forbidden(let detail):
            return SCIMErrorResponse(
                detail: detail ?? "Permission denied",
                status: String(statusCode),
                scimType: nil
            )
        case .invalidFilter(let detail):
            return SCIMErrorResponse(
                detail: detail,
                status: String(statusCode),
                scimType: SCIMErrorType.invalidFilter.rawValue
            )
        case .invalidPath(let detail):
            return SCIMErrorResponse(
                detail: detail,
                status: String(statusCode),
                scimType: SCIMErrorType.invalidPath.rawValue
            )
        case .noTarget(let detail):
            return SCIMErrorResponse(
                detail: detail,
                status: String(statusCode),
                scimType: SCIMErrorType.noTarget.rawValue
            )
        case .mutability(let detail):
            return SCIMErrorResponse(
                detail: detail,
                status: String(statusCode),
                scimType: SCIMErrorType.mutability.rawValue
            )
        case .tooMany(let maxResults):
            return SCIMErrorResponse(
                detail: "Too many results. Maximum allowed is \(maxResults)",
                status: String(statusCode),
                scimType: SCIMErrorType.tooMany.rawValue
            )
        case .internalError(let detail):
            return SCIMErrorResponse(
                detail: detail,
                status: String(statusCode),
                scimType: nil
            )
        }
    }
}
