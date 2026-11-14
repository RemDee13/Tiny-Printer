import Foundation
import Network

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]   // lower-cased keys
    var body: Data

    func int(_ key: String) -> Int? { query[key].flatMap(Int.init) }
    func bool(_ key: String) -> Bool? { query[key].map { ["1", "true", "yes"].contains($0.lowercased()) } }
}

struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data + Data("\n".utf8))
    }

    static func error(_ message: String, status: Int = 400) -> HTTPResponse {
        json(["ok": false, "error": message], status: status)
    }

    func serialized() -> Data {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 413: "Payload Too Large",
                      500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "Status"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// Minimal HTTP/1.1 server bound to 127.0.0.1 only. Used by the print-system handler and the `tinyprint` CLI.
final class LocalServer {
    static let maxBody = 64 * 1024 * 1024

    let port: UInt16
    private var listener: NWListener?
    private let handler: (HTTPRequest) async -> HTTPResponse

    init(port: UInt16, handler: @escaping (HTTPRequest) async -> HTTPResponse) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    func stop() { listener?.cancel() }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        var buffer = Data()
        var sentContinue = false

        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
                guard let self else { conn.cancel(); return }
                if let data { buffer.append(data) }
                switch HTTPParser.parse(buffer) {
                case .complete(let req):
                    Task {
                        let resp = await self.handler(req)
                        conn.send(content: resp.serialized(), completion: .contentProcessed { _ in conn.cancel() })
                    }
                case .needMore(let headersDone, let expectContinue, let tooBig):
                    if tooBig {
                        conn.send(content: HTTPResponse.error("payload too large", status: 413).serialized(),
                                  completion: .contentProcessed { _ in conn.cancel() })
                        return
                    }
                    if headersDone && expectContinue && !sentContinue {
                        sentContinue = true
                        conn.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
                    }
                    if isComplete || error != nil { conn.cancel() } else { receive() }
                case .invalid:
                    conn.send(content: HTTPResponse.error("bad request").serialized(),
                              completion: .contentProcessed { _ in conn.cancel() })
                }
            }
        }
        receive()
    }
}

enum HTTPParser {
    enum Result {
        case complete(HTTPRequest)
        case needMore(headersDone: Bool, expectContinue: Bool, tooBig: Bool)
        case invalid
    }

    static func parse(_ data: Data) -> Result {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 64 * 1024 ? .invalid : .needMore(headersDone: false, expectContinue: false, tooBig: false)
        }
        guard let head = String(data: data[data.startIndex..<sep.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        if length > LocalServer.maxBody { return .needMore(headersDone: true, expectContinue: false, tooBig: true) }
        let bodyStart = sep.upperBound
        guard data.count - bodyStart >= length else {
            return .needMore(headersDone: true, expectContinue: headers["expect"]?.lowercased() == "100-continue", tooBig: false)
        }
        let target = String(requestLine[1])
        let comps = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .complete(HTTPRequest(method: String(requestLine[0]).uppercased(), path: comps?.path ?? target,
                                     query: query, headers: headers,
                                     body: data.subdata(in: bodyStart..<(bodyStart + length))))
    }
}
