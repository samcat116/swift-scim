import Foundation

/// Configuration for the SCIM request processor
public struct SCIMProcessorConfiguration: Sendable {
    /// Base URL for the SCIM server
    public let baseURL: URL

    /// Maximum results per page
    public let maxResults: Int

    /// Default results per page
    public let defaultPageSize: Int

    /// Service provider configuration
    public let serviceProviderConfig: SCIMServiceProviderConfig?

    /// Resource type definitions
    public let resourceTypes: [SCIMResourceType]

    /// Schema definitions
    public let schemas: [SCIMSchema]

    public init(
        baseURL: URL,
        maxResults: Int = 1000,
        defaultPageSize: Int = 100,
        serviceProviderConfig: SCIMServiceProviderConfig? = nil,
        resourceTypes: [SCIMResourceType] = [],
        schemas: [SCIMSchema] = []
    ) {
        self.baseURL = baseURL
        self.maxResults = maxResults
        self.defaultPageSize = defaultPageSize
        self.serviceProviderConfig = serviceProviderConfig
        self.resourceTypes = resourceTypes
        self.schemas = schemas
    }
}

/// Main SCIM request processor that routes requests to appropriate handlers
///
/// Example usage:
/// ```swift
/// let processor = SCIMRequestProcessor(
///     configuration: SCIMProcessorConfiguration(
///         baseURL: URL(string: "https://example.com/scim/v2")!
///     )
/// )
/// await processor.register(UserHandler())
/// await processor.register(GroupHandler())
///
/// // In your HTTP framework handler:
/// let scimRequest = SCIMRequest(method: .GET, path: "/Users/123")
/// let scimResponse = await processor.process(scimRequest)
/// ```
public actor SCIMRequestProcessor {
    private let configuration: SCIMProcessorConfiguration
    private var handlers: [String: any SCIMResourceHandlerBox] = [:]
    private let authenticator: (any SCIMServerAuthenticator)?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        configuration: SCIMProcessorConfiguration,
        authenticator: (any SCIMServerAuthenticator)? = nil
    ) {
        self.configuration = configuration
        self.authenticator = authenticator

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    /// Register a resource handler
    public func register<H: SCIMResourceHandler>(_ handler: H) {
        handlers[H.endpoint] = SCIMResourceHandlerBoxImpl(handler)
    }

    /// Process an incoming SCIM request
    /// - Parameter request: The incoming request
    /// - Returns: The SCIM response
    public func process(_ request: SCIMRequest) async -> SCIMResponse {
        do {
            // Authenticate if authenticator is set
            let authContext: SCIMAuthContext
            if let authenticator = authenticator {
                authContext = try await authenticator.authenticate(request: request)
            } else {
                authContext = .anonymous
            }

            // Parse the request path
            let parsedPath = request.parsePath()

            // Create request context
            let context = SCIMRequestContext(
                auth: authContext,
                baseURL: configuration.baseURL,
                request: request
            )

            // Route to appropriate handler
            return try await routeRequest(request: request, parsedPath: parsedPath, context: context)

        } catch let error as SCIMServerError {
            return SCIMResponse.error(error)
        } catch {
            return SCIMResponse.error(.internalError(detail: error.localizedDescription))
        }
    }

    // MARK: - Private Routing

    private func routeRequest(request: SCIMRequest, parsedPath: SCIMRequest.ParsedPath, context: SCIMRequestContext) async throws -> SCIMResponse {
        // Handle service provider endpoints
        if let endpoint = parsedPath.endpoint {
            switch endpoint {
            case "ServiceProviderConfig":
                return try handleServiceProviderConfig()
            case "ResourceTypes":
                return try handleResourceTypes(id: parsedPath.resourceId)
            case "Schemas":
                return try handleSchemas(id: parsedPath.resourceId)
            case "Bulk":
                return try await handleBulk(request: request, context: context)
            default:
                break
            }
        }

        // Handle root-level search
        if parsedPath.endpoint == nil && parsedPath.isSearch {
            return try await handleRootSearch(request: request, context: context)
        }

        // Route to resource handler
        guard let endpoint = parsedPath.endpoint,
              let handler = handlers[endpoint] else {
            if parsedPath.endpoint == nil {
                // Root request - return service info or error
                return SCIMResponse.badRequest(detail: "No endpoint specified")
            }
            throw SCIMServerError.notFound(resourceType: parsedPath.endpoint ?? "Unknown", id: "")
        }

        // Handle search
        if parsedPath.isSearch {
            let query = try SCIMServerQuery(
                from: request.queryParameters,
                maxResults: configuration.maxResults,
                defaultCount: configuration.defaultPageSize
            )
            return try await handler.handleSearch(query: query, context: context)
        }

        // Route based on method and path
        switch request.method {
        case .GET:
            if let id = parsedPath.resourceId {
                return try await handler.handleGet(id: id, context: context)
            } else {
                // List/search
                let query = try SCIMServerQuery(
                    from: request.queryParameters,
                    maxResults: configuration.maxResults,
                    defaultCount: configuration.defaultPageSize
                )
                return try await handler.handleSearch(query: query, context: context)
            }

        case .POST:
            guard let body = request.body else {
                throw SCIMServerError.badRequest(detail: "Request body required", scimType: .invalidSyntax)
            }
            return try await handler.handleCreate(body: body, context: context)

        case .PUT:
            guard let id = parsedPath.resourceId else {
                throw SCIMServerError.badRequest(detail: "Resource ID required for PUT", scimType: .invalidSyntax)
            }
            guard let body = request.body else {
                throw SCIMServerError.badRequest(detail: "Request body required", scimType: .invalidSyntax)
            }
            return try await handler.handleReplace(id: id, body: body, context: context)

        case .PATCH:
            guard let id = parsedPath.resourceId else {
                throw SCIMServerError.badRequest(detail: "Resource ID required for PATCH", scimType: .invalidSyntax)
            }
            guard let body = request.body else {
                throw SCIMServerError.badRequest(detail: "Request body required", scimType: .invalidSyntax)
            }
            return try await handler.handlePatch(id: id, body: body, context: context)

        case .DELETE:
            guard let id = parsedPath.resourceId else {
                throw SCIMServerError.badRequest(detail: "Resource ID required for DELETE", scimType: .invalidSyntax)
            }
            return try await handler.handleDelete(id: id, context: context)
        }
    }

    // MARK: - Service Provider Endpoints

    private func handleServiceProviderConfig() throws -> SCIMResponse {
        guard let config = configuration.serviceProviderConfig else {
            // Return a default config
            let defaultConfig = SCIMServiceProviderConfig(
                patch: SCIMFeatureConfig(supported: true),
                bulk: SCIMBulkConfig(
                    supported: false,
                    maxOperations: 0,
                    maxPayloadSize: 0
                ),
                filter: SCIMFilterConfig(
                    supported: true,
                    maxResults: configuration.maxResults
                ),
                changePassword: SCIMFeatureConfig(supported: false),
                sort: SCIMFeatureConfig(supported: true),
                etag: SCIMFeatureConfig(supported: true),
                authenticationSchemes: []
            )
            return try SCIMResponse.ok(defaultConfig)
        }
        return try SCIMResponse.ok(config)
    }

    private func handleResourceTypes(id: String?) throws -> SCIMResponse {
        if let id = id {
            // Return specific resource type
            guard let resourceType = configuration.resourceTypes.first(where: { $0.id == id || $0.name == id }) else {
                throw SCIMServerError.notFound(resourceType: "ResourceType", id: id)
            }
            return try SCIMResponse.ok(resourceType)
        } else {
            // Return all resource types
            let response = SCIMListResponse(
                totalResults: configuration.resourceTypes.count,
                resources: configuration.resourceTypes
            )
            return try SCIMResponse.ok(response)
        }
    }

    private func handleSchemas(id: String?) throws -> SCIMResponse {
        if let id = id {
            // Return specific schema
            guard let schema = configuration.schemas.first(where: { $0.id == id }) else {
                throw SCIMServerError.notFound(resourceType: "Schema", id: id)
            }
            return try SCIMResponse.ok(schema)
        } else {
            // Return all schemas
            let response = SCIMListResponse(
                totalResults: configuration.schemas.count,
                resources: configuration.schemas
            )
            return try SCIMResponse.ok(response)
        }
    }

    private func handleBulk(request: SCIMRequest, context: SCIMRequestContext) async throws -> SCIMResponse {
        // Bulk operations not implemented yet
        throw SCIMServerError.badRequest(detail: "Bulk operations not supported", scimType: .none)
    }

    private func handleRootSearch(request: SCIMRequest, context: SCIMRequestContext) async throws -> SCIMResponse {
        // Root-level search across all resource types not implemented yet
        throw SCIMServerError.badRequest(detail: "Root-level search not supported", scimType: .none)
    }
}
