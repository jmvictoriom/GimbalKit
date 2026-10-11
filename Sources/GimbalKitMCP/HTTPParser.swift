import Foundation

public struct HTTPFailure: Error, Sendable, Equatable {
    public let status: Int
    public init(_ status: Int) { self.status = status }
}
public struct HTTPRequest: Sendable {
    public let method: String
    public let target: String
    public let headers: [String: String]
    public let body: Data
}
public struct HTTPParser: Sendable {
    private var buffer = Data()
    private var header: (String, String, [String: String], Int, Int)?
    private var completed = false
    public init() {}
    public mutating func feed(_ data: Data) throws -> HTTPRequest? {
        guard !completed else { throw HTTPFailure(400) }
        guard data.count <= 8192 + 65536, buffer.count <= 8192 + 65536 - data.count else { throw HTTPFailure(413) }
        buffer.append(data)
        if header == nil {
            guard let delimiter = buffer.range(of: Data([13, 10, 13, 10])) else {
                guard buffer.count <= 8192 else { throw HTTPFailure(431) }
                return nil
            }
            let end = delimiter.upperBound
            guard end <= 8192 else { throw HTTPFailure(431) }
            let bytes = buffer[..<delimiter.lowerBound]
            guard bytes.allSatisfy({ $0 == 13 || $0 == 10 || $0 == 9 || (32...126).contains($0) }),
                  let text = String(data: bytes, encoding: .ascii) else { throw HTTPFailure(400) }
            let lines = text.components(separatedBy: "\r\n")
            guard lines.count <= 65 else { throw HTTPFailure(431) }
            let requestLine = lines[0].components(separatedBy: " ")
            guard requestLine.count == 3, requestLine[2] == "HTTP/1.1",
                  !requestLine[0].isEmpty, !requestLine[1].isEmpty else { throw HTTPFailure(400) }
            var fields: [String: String] = [:]
            let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~".utf8)
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw HTTPFailure(400) }
                let name = String(line[..<colon])
                guard !name.isEmpty, name.utf8.allSatisfy({ allowed.contains($0) }) else { throw HTTPFailure(400) }
                let key = name.lowercased()
                let raw = line[line.index(after: colon)...]
                guard !raw.contains("\r"), !raw.contains("\n"), fields[key] == nil else { throw HTTPFailure(400) }
                fields[key] = raw.trimmingCharacters(in: .whitespaces)
            }
            guard fields["transfer-encoding"] == nil else { throw HTTPFailure(400) }
            guard let lengthText = fields["content-length"] else { throw HTTPFailure(411) }
            guard !lengthText.isEmpty, lengthText.utf8.allSatisfy({ (48...57).contains($0) }),
                  let length = Int(lengthText) else { throw HTTPFailure(400) }
            guard length <= 65536 else { throw HTTPFailure(413) }
            header = (requestLine[0], requestLine[1], fields, end, length)
        }
        guard let (method, target, fields, end, length) = header else { return nil }
        guard buffer.count >= end + length else { return nil }
        guard buffer.count == end + length else { throw HTTPFailure(400) }
        completed = true
        return HTTPRequest(method: method, target: target, headers: fields, body: Data(buffer[end...]))
    }
}
public enum ConstantTime {
    public static func equal(_ presented: String, _ expected: String) -> Bool {
        let a = Array(presented.utf8), b = Array(expected.utf8)
        var difference = UInt64(a.count ^ b.count)
        // El número de iteraciones solo depende de la longitud pública del formato del token.
        for i in b.indices { difference |= UInt64((i < a.count ? a[i] : 0) ^ b[i]) }
        return difference == 0
    }
}
public struct HTTPGate: Sendable {
    private let port: UInt16
    private let token: String
    public init(port: UInt16, token: String) { self.port = port; self.token = token }
    public func validate(_ request: HTTPRequest) throws {
        let locals = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = request.headers["host"], locals.contains(host.lowercased()) else { throw HTTPFailure(403) }
        if let origin = request.headers["origin"], !locals.map({ "http://" + $0 }).contains(origin.lowercased()) {
            throw HTTPFailure(403)
        }
        guard ConstantTime.equal(request.headers["authorization"] ?? "", "Bearer " + token) else { throw HTTPFailure(401) }
        guard request.method == "POST" else { throw HTTPFailure(405) }
        guard request.target == "/mcp" else { throw HTTPFailure(404) }
        let contentType = request.headers["content-type"]?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
        guard contentType == "application/json" else { throw HTTPFailure(415) }
        let accepts = (request.headers["accept"] ?? "").lowercased().split(separator: ",").map {
            $0.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        guard accepts.contains("application/json") || accepts.contains("*/*") else { throw HTTPFailure(406) }
        if let version = request.headers["mcp-protocol-version"], !MCPDispatcher.versions.contains(version) { throw HTTPFailure(400) }
    }
}
