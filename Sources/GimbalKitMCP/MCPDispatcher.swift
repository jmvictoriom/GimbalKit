import Foundation
import GimbalKit

public struct RPCReply: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}
private enum RPCFailure: Error { case method, params }
public struct MCPDispatcher: Sendable {
    private let service: any GimbalService
    public init(service: any GimbalService) { self.service = service }
    public static let versions = ["2025-03-26", "2025-06-18"]
    public func respond(to data: Data) async -> RPCReply {
        let request: JSONValue
        do { request = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { return self.error(-32700, "Parse error", id: .null) }
        guard let object = request.object, request["jsonrpc"] == .string("2.0"),
              let method = request["method"].string,
              Set(object.keys).isSubset(of: ["jsonrpc", "id", "method", "params"]),
              validID(object["id"]) else { return error(-32600, "Invalid Request", id: .null) }
        // Una notificación jamás ejecuta una herramienta, incluso si dice tools/call.
        guard let id = object["id"] else { return RPCReply(status: 202, body: Data()) }
        let params = object["params"] ?? .object([:])
        do {
            guard let p = params.object else { throw RPCFailure.params }
            let result: JSONValue
            switch method {
            case "initialize":
                guard Set(p.keys) == ["protocolVersion", "capabilities", "clientInfo"],
                      let requested = p["protocolVersion"]?.string, p["capabilities"]?.object != nil,
                      let info = p["clientInfo"]?.object, info["name"]?.string != nil, info["version"]?.string != nil else {
                    throw RPCFailure.params
                }
                result = .object(["protocolVersion": .string(Self.versions.contains(requested) ? requested : Self.versions[Self.versions.count - 1]),
                                  "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                                  "serverInfo": .object(["name": .string("GimbalKit"), "version": .string("1.0")])])
            case "ping":
                guard p.isEmpty else { throw RPCFailure.params }; result = .object([:])
            case "tools/list":
                guard p.isEmpty else { throw RPCFailure.params }; result = .object(["tools": .array(Self.tools)])
            case "tools/call": result = try await call(p)
            default: throw RPCFailure.method
            }
            return reply(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
        } catch RPCFailure.method { return error(-32601, "Method not found", id: id) }
        catch RPCFailure.params { return error(-32602, "Invalid params", id: id) }
        catch { return self.error(-32603, "Internal error", id: id) }
    }
    private func validID(_ id: JSONValue?) -> Bool {
        switch id {
        case nil, .null?, .string?: true
        // Los IDs numéricos se limitan a Int32: por encima de 2^52 un Double ya no conserva la parte fraccionaria
        // y un ID como 9007199254740990.5 llegaría aquí como un entero válido.
        case let .number(n)?: n.isFinite && n.rounded() == n && abs(n) <= 2_147_483_647
        default: false
        }
    }
    private func call(_ p: [String: JSONValue]) async throws -> JSONValue {
        guard Set(p.keys).isSubset(of: ["name", "arguments"]), let name = p["name"]?.string,
              let args = (p["arguments"] ?? .object([:])).object else { throw RPCFailure.params }
        guard ["gimbal_status", "gimbal_zones", "gimbal_look", "gimbal_stop"].contains(name) else { throw RPCFailure.params }
        if name == "gimbal_look" {
            guard Set(args.keys).isSubset(of: ["zone", "lease_seconds"]),
                  let zone = args["zone"]?.string, !zone.isEmpty, zone.count <= 64,
                  args["lease_seconds"] == nil || args["lease_seconds"]?.number != nil else { throw RPCFailure.params }
            let seconds = args["lease_seconds"]?.number ?? 30
            guard seconds.isFinite, seconds > 0, seconds <= 30 else { throw RPCFailure.params }
        } else if !args.isEmpty { throw RPCFailure.params }
        do {
            let value: JSONValue
            switch name {
            case "gimbal_status": value = try JSONValue.encoded(await service.status())
            case "gimbal_zones": value = .object(["zones": try JSONValue.encoded(await service.zones())])
            case "gimbal_look":
                let result = try await service.look(zone: args["zone"]!.string!, leaseSeconds: args["lease_seconds"]?.number ?? 30)
                var fields = try JSONValue.encoded(result.status).object ?? [:]
                fields["arrivalPose"] = try JSONValue.encoded(result.arrivalPose)
                value = .object(fields)
            default: try await service.stop(); value = .object(["stopped": .bool(true)])
            }
            return try toolResult(value, isError: false)
        } catch {
            // No incluir errores arbitrarios del driver, paths ni credenciales.
            let code: String
            if error is CancellationError { code = "cancelled" }
            else if let e = error as? NavigationError { code = String(describing: e) }
            else if let e = error as? SafetyViolation { code = String(String(describing: e).prefix { $0 != "(" }) }
            else { code = "deviceUnavailable" }
            return try toolResult(.object(["error": .string(code)]), isError: true)
        }
    }
    private func toolResult(_ value: JSONValue, isError: Bool) throws -> JSONValue {
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        return .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                        "structuredContent": value, "isError": .bool(isError)])
    }
    private func reply(_ value: JSONValue) -> RPCReply {
        do { return RPCReply(status: 200, body: try JSONEncoder().encode(value)) }
        catch { return RPCReply(status: 200, body: Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)) }
    }
    private func error(_ code: Int, _ message: String, id: JSONValue) -> RPCReply {
        reply(.object(["jsonrpc": .string("2.0"), "id": id,
                       "error": .object(["code": .number(Double(code)), "message": .string(message)])]))
    }
    private static var tools: [JSONValue] {
        ["gimbal_status", "gimbal_zones", "gimbal_look", "gimbal_stop"].map { name in
            let properties: [String: JSONValue] = name == "gimbal_look" ? [
                "zone": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(64)]),
                "lease_seconds": .object(["type": .string("number"), "exclusiveMinimum": .number(0), "maximum": .number(30), "default": .number(30)])
            ] : [:]
            return .object(["name": .string(name), "description": .string(name),
                            "inputSchema": .object(["type": .string("object"), "properties": .object(properties),
                                                     "required": .array(name == "gimbal_look" ? [.string("zone")] : []),
                                                     "additionalProperties": .bool(false)])])
        }
    }
}
