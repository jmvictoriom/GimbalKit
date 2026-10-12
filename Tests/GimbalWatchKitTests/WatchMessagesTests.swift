import Foundation
import Testing
import GimbalWatchKit

@Suite struct WatchMessagesTests {
    @Test func requestsRoundTrip() throws {
        let session = UUID(), id = UUID()
        for request in [
            WatchRequest(session: session, seq: 0, operationID: id, stopToken: nil, command: .stop),
            WatchRequest(session: session, seq: UInt64.max, operationID: id, stopToken: UInt64.max, command: .look(zone: "mesa")),
            WatchRequest(session: session, seq: 2, operationID: nil, stopToken: nil, command: .status)
        ] {
            #expect(try WatchMessageCodec.decodeRequest(WatchMessageCodec.encodeRequest(request)) == request)
        }
    }

    @Test func eventsAndStatusRoundTrip() throws {
        let id = UUID()
        for session in [nil, UUID()] {
            for event in [WatchEvent.arrived(operationID: id, stopCounter: UInt64.max),
                          .stopped(operationID: id, stopCounter: 0), .rejected(operationID: id, reason: .unsafePath)] {
                let envelope = WatchEventEnvelope(session: session, event: event)
                #expect(try WatchMessageCodec.decodeEvent(WatchMessageCodec.encodeEvent(envelope)) == envelope)
                let status = WatchStatus(stopToken: UInt64.max, connected: true, batteryPercent: 100,
                    pose: WatchPose(yaw: -15, pitch: 22, roll: 0), zoneNames: ["mesa"], terminalEvent: envelope)
                #expect(try WatchMessageCodec.decodeStatus(WatchMessageCodec.encodeStatus(status)) == status)
            }
        }
        let empty = WatchStatus(stopToken: 0, connected: false, batteryPercent: nil, pose: nil, zoneNames: [])
        #expect(try WatchMessageCodec.decodeStatus(WatchMessageCodec.encodeStatus(empty)) == empty)
    }

    @Test func malformedRequestsAreRejected() {
        let valid = WatchMessageCodec.encodeRequest(WatchRequest(session: UUID(), seq: 1, operationID: UUID(),
            stopToken: 0, command: .look(zone: "mesa")))
        for (key, value) in [("session", "invalid" as Any), ("operationID", "invalid" as Any),
                             ("zone", " \n" as Any), ("zone", 3 as Any), ("extra", 1 as Any),
                             ("command", "speed" as Any), ("version", 2 as Any)] {
            var message = valid; message[key] = value
            #expect(throws: WatchMessageError.self) { try WatchMessageCodec.decodeRequest(message) }
        }
        for key in ["operationID", "stopToken", "session", "seq"] {
            var message = valid; message.removeValue(forKey: key)
            #expect(throws: WatchMessageError.self) { try WatchMessageCodec.decodeRequest(message) }
        }
    }

    @Test func invalidUnsignedNumbersAreRejected() {
        let request = WatchMessageCodec.encodeRequest(WatchRequest(session: UUID(), seq: 1, operationID: UUID(),
            stopToken: 0, command: .look(zone: "mesa")))
        let event = WatchMessageCodec.encodeEvent(WatchEventEnvelope(session: UUID(),
            event: .arrived(operationID: UUID(), stopCounter: 1)))
        for value in [NSNumber(value: -1), NSNumber(value: 1.5), NSNumber(value: true),
                      NSNumber(value: Double.nan), NSNumber(value: Double.infinity), "1" as Any] {
            for key in ["seq", "stopToken"] {
                var message = request; message[key] = value
                #expect(throws: WatchMessageError.self) { try WatchMessageCodec.decodeRequest(message) }
            }
            var message = event; message["stopCounter"] = value
            #expect(throws: WatchMessageError.self) { try WatchMessageCodec.decodeEvent(message) }
        }
    }

    @Test func malformedEventsAreRejected() {
        for event in [WatchEvent.arrived(operationID: UUID(), stopCounter: 0),
                      .stopped(operationID: UUID(), stopCounter: 0)] {
            let valid = WatchMessageCodec.encodeEvent(WatchEventEnvelope(session: UUID(), event: event))
            for key in ["stopCounter", "operationID"] {
                var message = valid; message.removeValue(forKey: key)
                #expect(throws: WatchMessageError.self) { try WatchMessageCodec.decodeEvent(message) }
            }
            for (key, value) in [("extra", 1 as Any), ("session", "bad" as Any), ("operationID", false as Any)] {
                var message = valid; message[key] = value
                #expect(throws: WatchMessageError.self) { try WatchMessageCodec.decodeEvent(message) }
            }
        }
        var rejection = WatchMessageCodec.encodeEvent(WatchEventEnvelope(session: nil,
            event: .rejected(operationID: UUID(), reason: .failed)))
        rejection["reason"] = "unknown"
        #expect(throws: WatchMessageError.self) { try WatchMessageCodec.decodeEvent(rejection) }
    }

    @Test func malformedStatusIsRejected() {
        let valid = WatchMessageCodec.encodeStatus(WatchStatus(stopToken: 0, connected: true, batteryPercent: 50,
            pose: WatchPose(yaw: 0, pitch: 0, roll: 0), zoneNames: ["mesa"]))
        for (key, value) in [("batteryPercent", -1 as Any), ("batteryPercent", 101 as Any),
                             ("batteryPercent", true as Any), ("batteryPercent", 1.5 as Any),
                             ("connected", 1 as Any), ("zones", [" "] as Any), ("extra", 1 as Any),
                             ("stopToken", -1 as Any), ("terminalEvent", "bad" as Any)] {
            var message = valid; message[key] = value
            #expect(throws: WatchMessageError.self) { try WatchMessageCodec.decodeStatus(message) }
        }
        for value in [NSNumber(value: Double.nan), NSNumber(value: Double.infinity), NSNumber(value: true)] {
            var message = valid; message["pose"] = ["yaw": value, "pitch": 0, "roll": 0]
            #expect(throws: WatchMessageError.self) { try WatchMessageCodec.decodeStatus(message) }
        }
    }

    @Test func immediateAndContextTerminalUseTheSameReducerOnce() throws {
        let id = UUID(), event = WatchEvent.arrived(operationID: UUID(), stopCounter: 4)
        var reducer = WatchOperationState(); reducer.begin(id)
        #expect(reducer.apply(event) == nil)
        let arrival = WatchEvent.arrived(operationID: id, stopCounter: 4)
        let status = WatchStatus(stopToken: 4, connected: true, batteryPercent: 80, pose: nil,
            zoneNames: ["mesa"], terminalEvent: WatchEventEnvelope(session: UUID(), event: arrival))
        let recovered = try WatchMessageCodec.decodeStatus(WatchMessageCodec.encodeStatus(status))
        #expect(recovered == status)
        #expect(reducer.apply(arrival) == arrival)
        #expect(reducer.apply(try #require(recovered.terminalEvent).event) == nil)
        #expect(reducer.currentOperationID == nil)
        reducer.begin(id)
        let rejected = WatchEvent.rejected(operationID: id, reason: .referenceRequired)
        #expect(reducer.apply(rejected) == rejected)
        #expect(reducer.currentOperationID == nil)
    }

    @Test func reducerDiscardsArrivalOlderThanKnownStop() {
        let id = UUID(); var reducer = WatchOperationState(); reducer.begin(id)
        reducer.observeStopToken(5)
        reducer.observeStopToken(4)
        #expect(reducer.apply(.arrived(operationID: id, stopCounter: 4)) == nil)
        #expect(reducer.currentOperationID == id)
        let stopped = WatchEvent.stopped(operationID: id, stopCounter: 4)
        #expect(reducer.apply(stopped) == stopped)
        #expect(reducer.currentOperationID == nil)
    }
}
