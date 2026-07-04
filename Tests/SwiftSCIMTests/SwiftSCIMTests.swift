import Testing
import Foundation
@testable import SwiftSCIM

@Test func libraryVersion() {
    #expect(SwiftSCIM.version == "1.0.0")
}

@Test func scimUserCreation() {
    let user = SCIMUser(userName: "testuser")
    #expect(user.userName == "testuser")
    #expect(user.schemas.first == "urn:ietf:params:scim:schemas:core:2.0:User")
}

@Test func scimGroupCreation() {
    let group = SCIMGroup(displayName: "Test Group")
    #expect(group.displayName == "Test Group")
    #expect(group.schemas.first == "urn:ietf:params:scim:schemas:core:2.0:Group")
}

@Test func scimFilterBuilding() {
    let filter = SCIMFilterDSL.filter {
        SCIMFilterDSL.eq("userName", "testuser")
    }
    #expect(filter.expression == "userName eq \"testuser\"")
}

@Test func complexSCIMFilter() {
    let filter = SCIMFilterDSL.filter {
        SCIMFilterDSL.and(
            SCIMFilterDSL.eq("active", "true"),
            SCIMFilterDSL.co("emails.value", "@example.com")
        )
    }
    #expect(filter.expression == "(active eq \"true\" and emails.value co \"@example.com\")")
}

@Test func scimUserWithMultiValuedAttributes() {
    let emails = [
        SCIMMultiValuedAttribute(value: "primary@example.com", type: "work", primary: true),
        SCIMMultiValuedAttribute(value: "secondary@example.com", type: "personal", primary: false)
    ]
    
    let user = SCIMUser(
        userName: "testuser",
        displayName: "Test User",
        emails: emails
    )
    
    #expect(user.emails?.count == 2)
    #expect(user.emails?.first?.value == "primary@example.com")
    #expect(user.emails?.first?.primary == true)
}

@Test func scimPatchOperations() {
    let patchRequest = SCIMPatchRequest(operations: [
        .replace(path: "active", boolValue: false),
        .add(path: "displayName", stringValue: "Updated Name")
    ])
    
    #expect(patchRequest.Operations.count == 2)
    #expect(patchRequest.Operations[0].op == .replace)
    #expect(patchRequest.Operations[1].op == .add)
}

@Test func scimQueryParameters() {
    let queryParams = SCIMQueryParameters(
        filter: SCIMFilter("userName eq \"test\""),
        attributes: ["userName", "displayName"],
        startIndex: 1,
        count: 10
    )
    
    let queryItems = queryParams.queryItems
    #expect(queryItems.contains { $0.name == "filter" && $0.value == "userName eq \"test\"" })
    #expect(queryItems.contains { $0.name == "attributes" && $0.value == "userName,displayName" })
    #expect(queryItems.contains { $0.name == "startIndex" && $0.value == "1" })
    #expect(queryItems.contains { $0.name == "count" && $0.value == "10" })
}

@Test func scimClientInitialization() async {
    let baseURL = URL(string: "https://api.example.com/scim/v2")!
    let authProvider = await BearerTokenAuthenticationProvider(token: "test-token")
    
    let client = SCIMClient(
        baseURL: baseURL,
        authenticationProvider: authProvider
    )
    
    #expect(client != nil)
}

@Test func bearerTokenAuthentication() async throws {
    let authProvider = await BearerTokenAuthenticationProvider(token: "test-token")
    let isValid = await authProvider.isValid
    #expect(isValid == true)
    
    var request = URLRequest(url: URL(string: "https://example.com")!)
    try await authProvider.authenticate(request: &request)
    
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
}

@Test func scimErrorTypes() {
    let error = SCIMClientError.resourceNotFound
    #expect(error.localizedDescription == "Resource not found")
}

@Test func dateParsingAcceptsFractionalAndWholeSeconds() {
    let withFractional = SCIMClient.parseSCIMDate("2026-03-21T12:34:56.000Z")
    let withoutFractional = SCIMClient.parseSCIMDate("2026-03-21T12:34:56Z")

    #expect(withFractional != nil)
    #expect(withoutFractional != nil)
    #expect(withFractional == withoutFractional)
    #expect(SCIMClient.parseSCIMDate("not a date") == nil)
}

@Test func formURLEncodingEscapesReservedCharacters() {
    #expect("a+b=c&d/e".formURLEncoded == "a%2Bb%3Dc%26d%2Fe")
    #expect("simple-token_1.0~x".formURLEncoded == "simple-token_1.0~x")
    #expect("secret with spaces".formURLEncoded == "secret%20with%20spaces")
}

#if canImport(Darwin)
/// URLProtocol mock for exercising the client against canned HTTP responses
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct SCIMClientNetworkTests {
    private func makeClient() -> SCIMClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return SCIMClient(
            baseURL: URL(string: "https://api.example.com/scim/v2")!,
            httpClient: URLSession(configuration: configuration)
        )
    }

    @Test func patchUserFallsBackToGetOn204NoContent() async throws {
        let userJSON = Data("""
        {
            "schemas": ["urn:ietf:params:scim:schemas:core:2.0:User"],
            "id": "user-123",
            "userName": "testuser",
            "active": false,
            "meta": {
                "resourceType": "User",
                "created": "2026-03-21T12:34:56Z",
                "lastModified": "2026-03-21T12:34:56.789Z"
            }
        }
        """.utf8)

        MockURLProtocol.handler = { request in
            let statusCode = request.httpMethod == "PATCH" ? 204 : 200
            let body = request.httpMethod == "PATCH" ? Data() : userJSON
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, body)
        }

        let patchRequest = SCIMPatchRequest(operation: .replace(path: "active", boolValue: false))
        let user = try await makeClient().patchUser(id: "user-123", patchRequest: patchRequest)

        #expect(user.id == "user-123")
        #expect(user.active == false)
        // meta timestamps decode whether or not they carry fractional seconds
        #expect(user.meta?.created != nil)
        #expect(user.meta?.lastModified != nil)
    }

    @Test func patchGroupDecodesBodyWhenPresent() async throws {
        let groupJSON = Data("""
        {
            "schemas": ["urn:ietf:params:scim:schemas:core:2.0:Group"],
            "id": "group-456",
            "displayName": "Test Group"
        }
        """.utf8)

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, groupJSON)
        }

        let patchRequest = SCIMPatchRequest(operation: .replace(path: "displayName", stringValue: "Test Group"))
        let group = try await makeClient().patchGroup(id: "group-456", patchRequest: patchRequest)

        #expect(group.id == "group-456")
        #expect(group.displayName == "Test Group")
    }
}
#endif
