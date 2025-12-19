import Foundation

/// Authentication context containing identity information
public struct SCIMAuthContext: Sendable {
    /// The authenticated principal (user/service identity)
    public let principal: String

    /// Optional tenant identifier for multi-tenant servers
    public let tenantId: String?

    /// Custom attributes from authentication
    public let attributes: [String: String]

    public init(
        principal: String,
        tenantId: String? = nil,
        attributes: [String: String] = [:]
    ) {
        self.principal = principal
        self.tenantId = tenantId
        self.attributes = attributes
    }

    /// Anonymous auth context for unauthenticated requests
    public static let anonymous = SCIMAuthContext(principal: "anonymous")
}

/// Context passed to handlers for each request
public struct SCIMRequestContext: Sendable {
    /// Authentication context
    public let auth: SCIMAuthContext

    /// Base URL of the SCIM server (for generating resource locations)
    public let baseURL: URL

    /// The original request
    public let request: SCIMRequest

    /// Request-scoped metadata
    public let metadata: [String: String]

    public init(
        auth: SCIMAuthContext,
        baseURL: URL,
        request: SCIMRequest,
        metadata: [String: String] = [:]
    ) {
        self.auth = auth
        self.baseURL = baseURL
        self.request = request
        self.metadata = metadata
    }

    /// Generate a resource location URL
    /// - Parameters:
    ///   - endpoint: The resource endpoint (e.g., "Users")
    ///   - id: The resource ID
    /// - Returns: The full location URL string
    public func resourceLocation(endpoint: String, id: String) -> String {
        baseURL.appendingPathComponent(endpoint).appendingPathComponent(id).absoluteString
    }
}
