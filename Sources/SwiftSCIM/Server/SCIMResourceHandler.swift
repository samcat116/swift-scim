import Foundation

/// Protocol for handling SCIM resource operations
///
/// Implement this protocol for each resource type (User, Group, custom resources).
/// The handler is responsible for CRUD operations and search functionality.
///
/// Example implementation:
/// ```swift
/// struct UserHandler: SCIMResourceHandler {
///     typealias Resource = SCIMUser
///     static let endpoint = "Users"
///     static let schemaURI = "urn:ietf:params:scim:schemas:core:2.0:User"
///
///     let database: Database
///
///     func create(_ resource: SCIMUser, context: SCIMRequestContext) async throws -> SCIMUser {
///         let id = UUID().uuidString
///         let now = Date()
///         let meta = SCIMResourceMeta(
///             resourceType: "User",
///             created: now,
///             lastModified: now,
///             location: context.resourceLocation(endpoint: Self.endpoint, id: id),
///             version: "W/\"\(now.timeIntervalSince1970)\""
///         )
///         // Save to database and return with id and meta
///     }
/// }
/// ```
public protocol SCIMResourceHandler<Resource>: Sendable {
    /// The resource type this handler manages
    associatedtype Resource: SCIMResource

    /// The endpoint path for this resource (e.g., "Users", "Groups")
    static var endpoint: String { get }

    /// The schema URI for this resource type
    static var schemaURI: String { get }

    /// Create a new resource
    /// - Parameters:
    ///   - resource: The resource to create (without server-generated fields)
    ///   - context: Request context containing auth info, base URL, etc.
    /// - Returns: The created resource with server-generated id and meta
    /// - Throws: `SCIMServerError.conflict` if resource already exists
    func create(_ resource: Resource, context: SCIMRequestContext) async throws -> Resource

    /// Retrieve a resource by ID
    /// - Parameters:
    ///   - id: The resource identifier
    ///   - context: Request context
    /// - Returns: The resource if found
    /// - Throws: `SCIMServerError.notFound` if resource doesn't exist
    func get(id: String, context: SCIMRequestContext) async throws -> Resource

    /// Replace a resource entirely (PUT)
    /// - Parameters:
    ///   - id: The resource identifier
    ///   - resource: The replacement resource
    ///   - context: Request context
    /// - Returns: The updated resource
    /// - Throws: `SCIMServerError.notFound` if resource doesn't exist
    func replace(id: String, with resource: Resource, context: SCIMRequestContext) async throws -> Resource

    /// Delete a resource
    /// - Parameters:
    ///   - id: The resource identifier
    ///   - context: Request context
    /// - Throws: `SCIMServerError.notFound` if resource doesn't exist
    func delete(id: String, context: SCIMRequestContext) async throws

    /// Search/list resources
    /// - Parameters:
    ///   - query: Query parameters (filter, pagination, sorting)
    ///   - context: Request context
    /// - Returns: List response with matching resources
    func search(query: SCIMServerQuery, context: SCIMRequestContext) async throws -> SCIMListResponse<Resource>

    /// Apply PATCH operations to a resource
    /// - Parameters:
    ///   - id: The resource identifier
    ///   - operations: The PATCH operations to apply
    ///   - context: Request context
    /// - Returns: The modified resource
    /// - Throws: `SCIMServerError.notFound` if resource doesn't exist
    func patch(id: String, operations: [SCIMPatchOperation], context: SCIMRequestContext) async throws -> Resource
}

// MARK: - Default Implementation

extension SCIMResourceHandler {
    /// Default implementation for patch using get + apply + replace
    public func patch(id: String, operations: [SCIMPatchOperation], context: SCIMRequestContext) async throws -> Resource {
        let resource = try await get(id: id, context: context)
        let patchedResource = try SCIMPatchApplicator.apply(operations, to: resource)
        return try await replace(id: id, with: patchedResource, context: context)
    }
}

// MARK: - Type-erased Handler Box

/// Type-erased wrapper for SCIMResourceHandler
/// This allows storing handlers of different resource types in a single collection
public protocol SCIMResourceHandlerBox: Sendable {
    /// The endpoint this handler manages
    var endpoint: String { get }

    /// The schema URI for this handler's resource type
    var schemaURI: String { get }

    /// Process a create request
    func handleCreate(body: Data, context: SCIMRequestContext) async throws -> SCIMResponse

    /// Process a get request
    func handleGet(id: String, context: SCIMRequestContext) async throws -> SCIMResponse

    /// Process a replace request
    func handleReplace(id: String, body: Data, context: SCIMRequestContext) async throws -> SCIMResponse

    /// Process a delete request
    func handleDelete(id: String, context: SCIMRequestContext) async throws -> SCIMResponse

    /// Process a search request
    func handleSearch(query: SCIMServerQuery, context: SCIMRequestContext) async throws -> SCIMResponse

    /// Process a patch request
    func handlePatch(id: String, body: Data, context: SCIMRequestContext) async throws -> SCIMResponse
}

/// Concrete implementation of SCIMResourceHandlerBox
public struct SCIMResourceHandlerBoxImpl<H: SCIMResourceHandler>: SCIMResourceHandlerBox {
    private let handler: H
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public var endpoint: String { H.endpoint }
    public var schemaURI: String { H.schemaURI }

    public init(_ handler: H) {
        self.handler = handler
        self.decoder = SCIMRequest.defaultDecoder
        self.encoder = SCIMResponse.defaultEncoder
    }

    public func handleCreate(body: Data, context: SCIMRequestContext) async throws -> SCIMResponse {
        let resource = try decoder.decode(H.Resource.self, from: body)
        let created = try await handler.create(resource, context: context)

        guard let id = created.id else {
            throw SCIMServerError.internalError(detail: "Created resource has no ID")
        }

        let location = context.resourceLocation(endpoint: endpoint, id: id)
        let etag = created.meta?.version
        return try SCIMResponse.created(created, location: location, etag: etag)
    }

    public func handleGet(id: String, context: SCIMRequestContext) async throws -> SCIMResponse {
        let resource = try await handler.get(id: id, context: context)
        let location = context.resourceLocation(endpoint: endpoint, id: id)
        let etag = resource.meta?.version
        return try SCIMResponse.ok(resource, location: location, etag: etag)
    }

    public func handleReplace(id: String, body: Data, context: SCIMRequestContext) async throws -> SCIMResponse {
        let resource = try decoder.decode(H.Resource.self, from: body)
        let updated = try await handler.replace(id: id, with: resource, context: context)
        let location = context.resourceLocation(endpoint: endpoint, id: id)
        let etag = updated.meta?.version
        return try SCIMResponse.ok(updated, location: location, etag: etag)
    }

    public func handleDelete(id: String, context: SCIMRequestContext) async throws -> SCIMResponse {
        try await handler.delete(id: id, context: context)
        return SCIMResponse.noContent()
    }

    public func handleSearch(query: SCIMServerQuery, context: SCIMRequestContext) async throws -> SCIMResponse {
        let response = try await handler.search(query: query, context: context)
        return try SCIMResponse.ok(response)
    }

    public func handlePatch(id: String, body: Data, context: SCIMRequestContext) async throws -> SCIMResponse {
        let patchRequest = try decoder.decode(SCIMPatchRequest.self, from: body)
        let patched = try await handler.patch(id: id, operations: patchRequest.Operations, context: context)
        let location = context.resourceLocation(endpoint: endpoint, id: id)
        let etag = patched.meta?.version
        return try SCIMResponse.ok(patched, location: location, etag: etag)
    }
}
