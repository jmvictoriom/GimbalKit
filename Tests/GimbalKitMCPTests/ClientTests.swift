import Foundation
import Testing
@testable import GimbalKitMCP

@MainActor @Test func cliCommandsUseMCPAndBadCredentialsFail() async throws {
    let fake = FakeService()
    let server = HTTPServer(service: fake, token: testToken)
    let port = try await server.start(port: 0)
    let urlSession = session()
    let client = MCPClient(port: port, token: testToken, session: urlSession)
    do {
        let status = try await CLICommand(arguments: ["status"]).run(client: client)
        #expect(status["connected"] == .bool(true))
        #expect(try await CLICommand(arguments: ["zones"]).run(client: client)["zones"].array?.count == 1)
        _ = try await CLICommand(arguments: ["look", "mesa"]).run(client: client)
        _ = try await CLICommand(arguments: ["stop"]).run(client: client)
        let looks = await fake.looks.count
        let stops = await fake.stops
        #expect(looks == 1 && stops == 1)
        let bad = MCPClient(port: port, token: "wrong", session: urlSession)
        await #expect(throws: CLIError.http(401)) { try await bad.tool("gimbal_status") }
        await #expect(throws: CLIError.tool("unsafePath")) { try await client.tool("gimbal_look", arguments: ["zone": .string("fallo")]) }
        for args in [[], ["look"], ["look", "mesa", "extra"], ["create", "mesa"], ["status", "--source=app"]] {
            #expect(throws: CLIError.usage) { try CLICommand(arguments: args) }
        }
    } catch { urlSession.invalidateAndCancel(); await server.stop(); throw error }
    urlSession.invalidateAndCancel(); await server.stop()
}

// URLSession transport fixture: no listener or socket is created.
private final class ClientHTTPFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count >= 0 else { throw CLIError.invalidResponse }
                    if count == 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try JSONDecoder().decode(JSONValue.self, from: data)
            let method = body["method"].string
            guard request.httpMethod == "POST", request.url?.host == "127.0.0.1",
                  request.url?.path == "/mcp",
                  request.value(forHTTPHeaderField: "Content-Type") == "application/json",
                  request.value(forHTTPHeaderField: "Accept") == "application/json, text/event-stream" else {
                throw CLIError.invalidResponse
            }
            if request.value(forHTTPHeaderField: "Authorization") != "Bearer " + testToken {
                deliver(status: 401, body: Data()); return
            }
            let result: JSONValue
            if method == "initialize" {
                guard body["params"]["protocolVersion"] == .string("2025-06-18") else { throw CLIError.invalidResponse }
                // Negotiate the older supported version to check subsequent headers.
                result = .object(["protocolVersion": .string("2025-03-26")])
            } else {
                guard request.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2025-03-26" else {
                    throw CLIError.invalidResponse
                }
                if method == "notifications/initialized" {
                    guard body.object?["id"] == nil else { throw CLIError.invalidResponse }
                    deliver(status: 202, body: Data()); return
                }
                guard method == "tools/call" else { throw CLIError.invalidResponse }
                let args = body["params"]["arguments"]
                let content: JSONValue
                let isError: Bool
                switch body["params"]["name"].string {
                case "gimbal_status": content = .object(["connected": .bool(true)]); isError = false
                case "gimbal_zones": content = .object(["zones": .array([.object(["name": .string("mesa")])])]); isError = false
                case "gimbal_stop": content = .object(["stopped": .bool(true)]); isError = false
                case "gimbal_look":
                    if args["zone"] == .string("fallo") {
                        content = .object(["error": .string("unsafePath")]); isError = true
                    } else {
                        guard args["zone"] == .string("mesa"), args["lease_seconds"] == .number(30) else {
                            throw CLIError.invalidResponse
                        }
                        content = .object(["connected": .bool(true),
                                           "battery": .object(["percent": .number(73), "charging": .bool(false)]),
                                           "lease": .object(["zone": .string("mesa"), "remainingSeconds": .number(29)]),
                                           "pose": .object(["yaw": .number(1)]),
                                           "arrivalPose": .object(["yaw": .number(1)])])
                        isError = false
                    }
                default: throw CLIError.invalidResponse
                }
                result = .object(["isError": .bool(isError), "structuredContent": content])
            }
            deliver(status: 200, body: try JSONEncoder().encode(JSONValue.object([
                "jsonrpc": .string("2.0"), "id": body["id"], "result": result])))
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    private func deliver(status: Int, body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func clientNegotiatesAndRunsCommandsWithHTTPFixtureWithoutSockets() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ClientHTTPFixture.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = MCPClient(port: 12345, token: testToken, session: session)
    #expect(try await CLICommand(arguments: ["status"]).run(client: client)["connected"] == .bool(true))
    #expect(try await CLICommand(arguments: ["zones"]).run(client: client)["zones"].array?.count == 1)
    let look = try await CLICommand(arguments: ["look", "mesa"]).run(client: client)
    #expect(look["connected"] == .bool(true))
    #expect(look["battery"]["percent"] == .number(73))
    #expect(look["lease"]["zone"] == .string("mesa"))
    #expect(look["lease"]["remainingSeconds"] == .number(29))
    #expect(look["arrivalPose"] == look["pose"])
    #expect(try await CLICommand(arguments: ["stop"]).run(client: client)["stopped"] == .bool(true))
    let bad = MCPClient(port: 12345, token: "wrong", session: session)
    await #expect(throws: CLIError.http(401)) { try await bad.tool("gimbal_status") }
    await #expect(throws: CLIError.tool("unsafePath")) { try await client.tool("gimbal_look", arguments: ["zone": .string("fallo")]) }
}

@Test func cliRejectsInvalidArgumentsWithoutContactingHost() {
    for args in [[], ["look"], ["look", "mesa", "extra"], ["create", "mesa"], ["status", "--source=app"]] {
        #expect(throws: CLIError.usage) { try CLICommand(arguments: args) }
    }
}
