#if !OFFLINE
import Foundation
import XCTest

/// URLProtocol stub for the Cloudflare client tests: no network, every request
/// (with its fully-read body) is logged, and a handler supplies the reply.
final class CloudflareFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()

        static func json(_ status: Int = 200, _ object: Any, headers: [String: String] = [:]) -> Reply {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return Reply(status: status, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a }, body: data)
        }
        static func envelope(_ result: Any, status: Int = 200) -> Reply {
            .json(status, ["success": true, "errors": [], "messages": [], "result": result])
        }
        static func failure(_ status: Int, code: Int, message: String) -> Reply {
            .json(status, ["success": false, "errors": [["code": code, "message": message]], "messages": [], "result": NSNull()])
        }
    }

    struct Recorded {
        let request: URLRequest
        let body: Data
        var method: String { request.httpMethod ?? "GET" }
        var path: String { request.url?.path ?? "" }
        func header(_ name: String) -> String? { request.value(forHTTPHeaderField: name) }
    }

    nonisolated static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((Recorded) throws -> Reply)?
    nonisolated(unsafe) static var log: [Recorded] = []

    static func install(_ handler: @escaping (Recorded) throws -> Reply) {
        lock.lock(); defer { lock.unlock() }
        Self.handler = handler
        log = []
    }
    static func uninstall() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
        log = []
    }
    static var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return log
    }
    static func requests(_ method: String) -> [Recorded] { requests.filter { $0.method == method } }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudflareFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }

    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    nonisolated override func stopLoading() {}
    nonisolated override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let recorded = Recorded(request: request, body: body)
        Self.lock.lock()
        Self.log.append(recorded)
        let handler = Self.handler
        Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.unsupportedURL) }
            let reply = try handler(recorded)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                           headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

/// Deterministic, non-repeating bytes so a misplaced chunk can't pass by luck.
func cloudflareTestBytes(count: Int) -> Data {
    var generator = SplitMix(seed: 0xC10D)
    var data = Data(count: count)
    data.withUnsafeMutableBytes { buffer in
        for index in 0..<buffer.count { buffer[index] = UInt8(truncatingIfNeeded: generator.next() >> 24) }
    }
    return data
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
#endif
