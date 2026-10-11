import Foundation
import Testing
@testable import GimbalKitMCP

let testToken = String(repeating: "a", count: 64)
func requestData(host: String = "127.0.0.1:12345", origin: String? = nil,
                 auth: String? = "Bearer " + testToken, extra: String = "", body: String = "{}") -> Data {
    var text = "POST /mcp HTTP/1.1\r\nHost: \(host)\r\nContent-Type: application/json\r\nAccept: application/json\r\n"
    if let origin { text += "Origin: \(origin)\r\n" }
    if let auth { text += "Authorization: \(auth)\r\n" }
    text += extra + "Content-Length: \(body.utf8.count)\r\n\r\n" + body
    return Data(text.utf8)
}
func parsed(_ data: Data) throws -> HTTPRequest {
    var parser = HTTPParser()
    let result = try parser.feed(data)
    return try #require(result)
}

@Test func fragmentedRequestParsesAndOnlyLocalAuthenticatedOriginsPass() throws {
    let data = requestData()
    var parser = HTTPParser()
    var result: HTTPRequest?
    for byte in data { if let r = try parser.feed(Data([byte])) { result = r } }
    let gate = HTTPGate(port: 12345, token: testToken)
    try gate.validate(try #require(result))
    try gate.validate(parsed(requestData(host: "localhost:12345", origin: "http://localhost:12345")))
    for host in ["evil.test:12345", "localhost.evil:12345", "127.1:12345", "127.0.0.1:99", "[::1]:12345"] {
        #expect(throws: HTTPFailure(403)) { try gate.validate(parsed(requestData(host: host))) }
    }
    for origin in ["null", "https://evil.test", "http://127.0.0.1:99", "http://localhost:12345/evil"] {
        #expect(throws: HTTPFailure(403)) { try gate.validate(parsed(requestData(origin: origin))) }
    }
    for auth in [nil, "Bearer " + String(repeating: "b", count: 64), "Bearer " + testToken + "a"] {
        #expect(throws: HTTPFailure(401)) { try gate.validate(parsed(requestData(auth: auth))) }
    }
    #expect(ConstantTime.equal(testToken, testToken))
    #expect(!ConstantTime.equal("b" + String(testToken.dropFirst()), testToken))
    #expect(!ConstantTime.equal(String(testToken.dropLast()) + "b", testToken))
    #expect(!ConstantTime.equal(testToken + String(repeating: "x", count: 256), testToken))
}

@Test func parserRejectsSmugglingOversizeAndMalformedLengths() throws {
    for extra in ["Content-Length: 2\r\n", "Transfer-Encoding: chunked\r\n", " Host: evil\r\n", "Host : evil\r\n"] {
        #expect(throws: HTTPFailure(400)) { try parsed(requestData(extra: extra)) }
    }
    for value in ["-1", "+2", "999999999999999999999999999", "2,2"] {
        let data = Data("POST /mcp HTTP/1.1\r\nHost: localhost:12345\r\nContent-Length: \(value)\r\n\r\n".utf8)
        #expect(throws: HTTPFailure.self) { try parsed(data) }
    }
    #expect(throws: HTTPFailure(413)) { try parsed(requestData(body: String(repeating: "x", count: 65537))) }
    #expect(throws: HTTPFailure(431)) { try parsed(requestData(extra: "X: " + String(repeating: "x", count: 8192) + "\r\n")) }
    #expect(throws: HTTPFailure(400)) { try parsed(requestData() + requestData()) }
    var partial = HTTPParser()
    #expect(try partial.feed(Data("POST /mcp HTTP/1.1\r\n".utf8)) == nil)
}
