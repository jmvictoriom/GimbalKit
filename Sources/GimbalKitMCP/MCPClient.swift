import Foundation

public enum CLIError: Error, Sendable, Equatable {
    case usage, http(Int), invalidResponse, rpc(Int), tool(String)
    public var message: String {
        switch self {
        case .usage: "Uso: gimbal status | zones | look <zona> | stop"
        case let .http(code): "El servidor respondió HTTP \(code)."
        case .invalidResponse: "Respuesta MCP inválida."
        case let .rpc(code): "Error JSON-RPC \(code)."
        case let .tool(code): "La herramienta falló: \(code)."
        }
    }
}
public struct MCPClient: Sendable {
    private let port: UInt16
    private let token: String
    private let session: URLSession
    public init(port: UInt16, token: String, session: URLSession = .shared) {
        self.port = port; self.token = token; self.session = session
    }
    public func tool(_ name: String, arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        let initialized = try await request(method: "initialize", params: .object([
            "protocolVersion": .string("2025-06-18"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("gimbal"), "version": .string("1.0")])]))
        guard let version = initialized["protocolVersion"].string, MCPDispatcher.versions.contains(version) else { throw CLIError.invalidResponse }
        _ = try await post(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]), version: version, notification: true)
        let result = try await request(method: "tools/call", params: .object(["name": .string(name), "arguments": .object(arguments)]), version: version)
        if result["isError"] == .bool(true) { throw CLIError.tool(result["structuredContent"]["error"].string ?? "deviceUnavailable") }
        guard result["isError"] == .bool(false), result.object?["structuredContent"] != nil else { throw CLIError.invalidResponse }
        return result["structuredContent"]
    }
    private func request(method: String, params: JSONValue, version: String? = nil) async throws -> JSONValue {
        let reply = try await post(.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string(method), "params": params]), version: version)
        guard reply["jsonrpc"] == .string("2.0"), reply["id"] == .number(1) else { throw CLIError.invalidResponse }
        if let code = reply["error"]["code"].number, code.isFinite, (-32768...0).contains(code) { throw CLIError.rpc(Int(code)) }
        guard reply.object?["result"] != nil else { throw CLIError.invalidResponse }
        return reply["result"]
    }
    private func post(_ value: JSONValue, version: String?, notification: Bool = false) async throws -> JSONValue {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(value)
        request.timeoutInterval = 35
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let version { request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CLIError.invalidResponse }
        guard http.statusCode == (notification ? 202 : 200) else { throw CLIError.http(http.statusCode) }
        if notification { guard data.isEmpty else { throw CLIError.invalidResponse }; return .null }
        guard data.count <= 1_048_576 else { throw CLIError.invalidResponse }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
public enum CLICommand: Sendable {
    case status, zones, look(String), stop
    public init(arguments: [String]) throws {
        switch arguments {
        case ["status"]: self = .status
        case ["zones"]: self = .zones
        case ["stop"]: self = .stop
        case let args where args.count == 2 && args[0] == "look" && !args[1].isEmpty: self = .look(args[1])
        default: throw CLIError.usage
        }
    }
    public func run(client: MCPClient) async throws -> JSONValue {
        switch self {
        case .status: try await client.tool("gimbal_status")
        case .zones: try await client.tool("gimbal_zones")
        case let .look(zone): try await client.tool("gimbal_look", arguments: ["zone": .string(zone), "lease_seconds": .number(30)])
        case .stop: try await client.tool("gimbal_stop")
        }
    }
}
