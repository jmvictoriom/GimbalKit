import Foundation
import Darwin
import GimbalKitMCP

@main struct GimbalCLI {
    static func main() async {
        do {
            let command = try CLICommand(arguments: Array(CommandLine.arguments.dropFirst()))
            let files = try LocalFiles()
            let token = try files.token(create: false)
            let port = try files.readEndpoint()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            configuration.timeoutIntervalForRequest = 35
            configuration.timeoutIntervalForResource = 40
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let result = try await command.run(client: MCPClient(port: port, token: token, session: session))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(result), as: UTF8.self))
        } catch {
            let message = (error as? CLIError)?.message ?? "No se pudo contactar con GimbalHostMac. Abra la app y active MCP."
            FileHandle.standardError.write(Data(("gimbal: " + message + "\n").utf8))
            exit(1)
        }
    }
}
