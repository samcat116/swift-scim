import Foundation

/// Protocol for server-side request authentication
///
/// Implement this protocol to authenticate incoming SCIM requests.
/// The authenticator is called before any handler processes the request.
///
/// Example implementation:
/// ```swift
/// struct BearerTokenAuthenticator: SCIMServerAuthenticator {
///     let tokenValidator: (String) async throws -> SCIMAuthContext
///
///     func authenticate(request: SCIMRequest) async throws -> SCIMAuthContext {
///         guard let authHeader = request.authorization,
///               authHeader.lowercased().hasPrefix("bearer ") else {
///             throw SCIMServerError.unauthorized(detail: "Bearer token required")
///         }
///         let token = String(authHeader.dropFirst(7))
///         return try await tokenValidator(token)
///     }
/// }
/// ```
public protocol SCIMServerAuthenticator: Sendable {
    /// Authenticate an incoming request
    /// - Parameter request: The incoming SCIM request
    /// - Returns: Authentication context with identity information
    /// - Throws: `SCIMServerError.unauthorized` if authentication fails
    func authenticate(request: SCIMRequest) async throws -> SCIMAuthContext
}

/// An authenticator that allows all requests without authentication
public struct NoOpAuthenticator: SCIMServerAuthenticator {
    public init() {}

    public func authenticate(request: SCIMRequest) async throws -> SCIMAuthContext {
        return .anonymous
    }
}

/// An authenticator that validates Bearer tokens
public struct BearerTokenAuthenticator: SCIMServerAuthenticator {
    public typealias TokenValidator = @Sendable (String) async throws -> SCIMAuthContext

    private let validator: TokenValidator

    public init(validator: @escaping TokenValidator) {
        self.validator = validator
    }

    public func authenticate(request: SCIMRequest) async throws -> SCIMAuthContext {
        guard let authHeader = request.authorization else {
            throw SCIMServerError.unauthorized(detail: "Authorization header required")
        }

        guard authHeader.lowercased().hasPrefix("bearer ") else {
            throw SCIMServerError.unauthorized(detail: "Bearer token required")
        }

        let token = String(authHeader.dropFirst(7))
        return try await validator(token)
    }
}

/// An authenticator that validates Basic authentication
public struct BasicAuthenticator: SCIMServerAuthenticator {
    public typealias CredentialValidator = @Sendable (String, String) async throws -> SCIMAuthContext

    private let validator: CredentialValidator

    public init(validator: @escaping CredentialValidator) {
        self.validator = validator
    }

    public func authenticate(request: SCIMRequest) async throws -> SCIMAuthContext {
        guard let authHeader = request.authorization else {
            throw SCIMServerError.unauthorized(detail: "Authorization header required")
        }

        guard authHeader.lowercased().hasPrefix("basic ") else {
            throw SCIMServerError.unauthorized(detail: "Basic authentication required")
        }

        let base64Credentials = String(authHeader.dropFirst(6))
        guard let credentialsData = Data(base64Encoded: base64Credentials),
              let credentials = String(data: credentialsData, encoding: .utf8) else {
            throw SCIMServerError.unauthorized(detail: "Invalid credentials format")
        }

        let parts = credentials.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else {
            throw SCIMServerError.unauthorized(detail: "Invalid credentials format")
        }

        let username = String(parts[0])
        let password = String(parts[1])
        return try await validator(username, password)
    }
}
