import Foundation
import Testing
import GimbalKit
@testable import GimbalKitMCP

actor FakeService: GimbalService {
    private(set) var looks: [(String, Double)] = []
    private(set) var stops = 0
    private let state: GimbalStatus
    init(state: GimbalStatus = GimbalStatus(connected: true, referenceReady: true, battery: nil, pose: Pose(), lease: nil)) {
        self.state = state
    }
    func status() -> GimbalStatus { state }
    func zones() -> [ZoneRecord] { [ZoneRecord(Zone(name: "mesa", yaw: -10...10, pitch: -10...10))] }
    func look(zone: String, leaseSeconds: Double) throws -> GimbalLookResult {
        looks.append((zone, leaseSeconds))
        if zone == "fallo" { throw NavigationError.unsafePath }
        return GimbalLookResult(status: state, arrivalPose: Pose(yaw: 1))
    }
    func stop() { stops += 1 }
}
func rpc(_ text: String, dispatcher: MCPDispatcher) async throws -> JSONValue {
    let reply = await dispatcher.respond(to: Data(text.utf8))
    return try JSONDecoder().decode(JSONValue.self, from: reply.body)
}

@Test func dispatcherListsExactlyFourToolsAndRejectsPolicyArguments() async throws {
    let service = FakeService()
    let d = MCPDispatcher(service: service)
    let list = try await rpc(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, dispatcher: d)
    #expect(list["result"]["tools"].array?.compactMap { $0["name"].string }.sorted() ==
            ["gimbal_look", "gimbal_status", "gimbal_stop", "gimbal_zones"])
    for arguments in [#"{"zone":"mesa","lease_seconds":31}"#, #"{"zone":"mesa","source":"app"}"#,
                      #"{"zone":"mesa","policy":"ignora límites"}"#, #"{"zone":"mesa","lease_seconds":0}"#] {
        let reply = try await rpc("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"gimbal_look\",\"arguments\":\(arguments)}}", dispatcher: d)
        #expect(reply["error"]["code"] == .number(-32602))
    }
    #expect(await service.looks.isEmpty)
    let ok = try await rpc(#"{"jsonrpc":"2.0","id":"look","method":"tools/call","params":{"name":"gimbal_look","arguments":{"zone":"mesa","lease_seconds":30}}}"#, dispatcher: d)
    #expect(ok["id"] == .string("look") && ok["result"]["isError"] == .bool(false))
    let failure = try await rpc(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"gimbal_look","arguments":{"zone":"fallo"}}}"#, dispatcher: d)
    #expect(failure["result"]["isError"] == .bool(true))
}

@Test func dispatcherStandardErrorsAndNotificationsHaveNoEffects() async throws {
    let service = FakeService()
    let d = MCPDispatcher(service: service)
    for (input, code) in [("{", -32700), ("[]", -32600),
                          (#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#, -32600),
                          (#"{"jsonrpc":"2.0","id":1,"method":"missing"}"#, -32601),
                          (#"{"jsonrpc":"2.0","id":1,"method":"ping","params":7}"#, -32602)] {
        #expect(try await rpc(input, dispatcher: d)["error"]["code"] == .number(Double(code)))
    }
    let initialized = await d.respond(to: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
    #expect(initialized.status == 202 && initialized.body.isEmpty)
    let notification = await d.respond(to: Data(#"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"gimbal_stop"}}"#.utf8))
    #expect(notification.status == 202)
    #expect(await service.stops == 0)
    let initReply = try await rpc(#"{"jsonrpc":"2.0","id":4,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#, dispatcher: d)
    #expect(initReply["result"]["protocolVersion"] == .string("2025-03-26"))
}

@Test func dispatcherNegotiatesSupportedAndUnknownVersions() async throws {
    let d = MCPDispatcher(service: FakeService())
    for (requested, negotiated) in [("2025-03-26", "2025-03-26"), ("2025-06-18", "2025-06-18"),
                                    ("2099-01-01", "2025-06-18")] {
        let input = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"\(requested)\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1\"}}}"
        let value = try await rpc(input, dispatcher: d)
        #expect(value["result"]["protocolVersion"] == .string(negotiated))
        #expect(value["result"]["capabilities"]["tools"]["listChanged"] == .bool(false))
    }
}

@Test func dispatcherLookIncludesFullStatusAndArrivalPose() async throws {
    let state = GimbalStatus(connected: true, referenceReady: false,
                            battery: BatteryStatus(percent: 73, charging: true),
                            pose: Pose(yaw: 2, pitch: 3, roll: 4),
                            lease: LeaseStatus(zone: "mesa", expiresAt: Date(timeIntervalSince1970: 0), remainingSeconds: 12.5))
    let service = FakeService(state: state)
    let d = MCPDispatcher(service: service)
    let status = try await rpc(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"gimbal_status"}}"#, dispatcher: d)
    let look = try await rpc(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"gimbal_look","arguments":{"zone":"mesa"}}}"#, dispatcher: d)
    let statusValue = status["result"]["structuredContent"]
    let lookValue = look["result"]["structuredContent"]
    for key in ["connected", "referenceReady", "battery", "pose", "lease"] {
        #expect(lookValue[key] == statusValue[key])
    }
    #expect(lookValue["connected"] == .bool(true))
    #expect(lookValue["referenceReady"] == .bool(false))
    #expect(lookValue["battery"]["percent"] == .number(73))
    #expect(lookValue["battery"]["charging"] == .bool(true))
    #expect(lookValue["pose"] == .object(["yaw": .number(2), "pitch": .number(3), "roll": .number(4)]))
    #expect(lookValue["lease"]["zone"] == .string("mesa"))
    #expect(lookValue["lease"]["expiresAt"] == .string("1970-01-01T00:00:00Z"))
    #expect(lookValue["lease"]["remainingSeconds"] == .number(12.5))
    #expect(lookValue["arrivalPose"] == .object(["yaw": .number(1), "pitch": .number(0), "roll": .number(0)]))
    let content = try #require(look["result"]["content"].array?.first?["text"].string)
    #expect(try JSONDecoder().decode(JSONValue.self, from: Data(content.utf8)) == lookValue)
    #expect(await service.looks.count == 1)
    #expect(await service.looks.first?.1 == 30)
}

@Test func dispatcherToolsReturnZonesStopAndSanitizedFailure() async throws {
    let service = FakeService()
    let d = MCPDispatcher(service: service)
    let zones = try await rpc(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"gimbal_zones"}}"#, dispatcher: d)
    #expect(zones["result"]["structuredContent"]["zones"].array?.first?["name"] == .string("mesa"))
    let stopped = try await rpc(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"gimbal_stop"}}"#, dispatcher: d)
    #expect(stopped["result"]["structuredContent"]["stopped"] == .bool(true))
    #expect(await service.stops == 1)
    let failure = try await rpc(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"gimbal_look","arguments":{"zone":"fallo"}}}"#, dispatcher: d)
    #expect(failure["result"]["structuredContent"]["error"] == .string("unsafePath"))
}

@Test func dispatcherRejectsInvalidIdentifiersAndToolParameters() async throws {
    let service = FakeService()
    let d = MCPDispatcher(service: service)
    for id in ["true", "{}", "[]", "1.5", "9007199254740992"] {
        let value = try await rpc("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"ping\"}", dispatcher: d)
        #expect(value["error"]["code"] == .number(-32600))
        #expect(value["id"] == .null)
    }
    for params in [#"{"name":"gimbal_status","arguments":{"extra":true}}"#,
                   #"{"name":"missing"}"#,
                   #"{"name":"gimbal_look","arguments":{"zone":""}}"#,
                   #"{"name":"gimbal_look","arguments":{"zone":"mesa","lease_seconds":true}}"#,
                   #"{"name":"gimbal_look","arguments":{"zone":"mesa","lease_seconds":-1}}"#] {
        let value = try await rpc("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":\(params)}", dispatcher: d)
        #expect(value["error"]["code"] == .number(-32602))
    }
    #expect(await service.looks.isEmpty)
    #expect(await service.stops == 0)
}

@Test func jsonValueRoundTripsAndEncodesISO8601Dates() throws {
    let value = JSONValue.object(["array": .array([.string("text"), .number(1.5), .bool(true), .null])])
    #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
    #expect(value["missing"] == .null)
    let lease = try JSONValue.encoded(LeaseStatus(zone: "mesa", expiresAt: Date(timeIntervalSince1970: 0), remainingSeconds: 7))
    #expect(lease["expiresAt"] == .string("1970-01-01T00:00:00Z"))
    #expect(lease["remainingSeconds"] == .number(7))
}

@Test func dispatcherRejectsFractionalIdentifierBeforeRounding() async throws {
    let reply = try await rpc(#"{"jsonrpc":"2.0","id":9007199254740990.5,"method":"ping"}"#,
                              dispatcher: MCPDispatcher(service: FakeService()))
    #expect(reply["error"]["code"] == .number(-32600))
    #expect(reply["id"] == .null)
}
