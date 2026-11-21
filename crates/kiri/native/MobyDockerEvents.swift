// Docker /events over the private Unix domain socket. No public daemon port.
import Darwin
import Foundation

/// Parses both ordinary HTTP and chunked Docker event streams incrementally.
struct MobyDockerEventStreamDecoder {
    enum DecodeError: Error { case invalidHTTP, tooLarge, ended }
    private var wire = Data()
    private var body = Data()
    private var headersSeen = false
    private var chunked = false
    private static let crlf = Data([13, 10])
    private static let endHeaders = Data([13, 10, 13, 10])
    private static let relevantKinds: Set<String> = [
        "container", "image", "volume", "network", "builder", "daemon"
    ]

    mutating func append(_ incoming: Data) throws -> Int {
        wire.append(incoming)
        if !headersSeen {
            guard let boundary = wire.range(of: Self.endHeaders) else {
                if wire.count > 32 * 1024 { throw DecodeError.tooLarge }
                return 0
            }
            let header = String(decoding: wire[..<boundary.lowerBound], as: UTF8.self)
            guard header.hasPrefix("HTTP/1.1 200") || header.hasPrefix("HTTP/1.0 200") else {
                throw DecodeError.invalidHTTP
            }
            chunked = header.lowercased().contains("transfer-encoding: chunked")
            wire.removeSubrange(..<boundary.upperBound)
            headersSeen = true
        }
        if chunked {
            while let end = wire.range(of: Self.crlf) {
                let head = String(decoding: wire[..<end.lowerBound], as: UTF8.self)
                guard let token = head.split(separator: ";", maxSplits: 1).first,
                      let length = Int(token, radix: 16), length >= 0,
                      length <= 512 * 1024 else { throw DecodeError.invalidHTTP }
                if length == 0 { throw DecodeError.ended }
                let payloadStart = end.upperBound
                guard wire.distance(from: payloadStart, to: wire.endIndex) >= length + 2 else {
                    break
                }
                let payloadEnd = wire.index(payloadStart, offsetBy: length)
                guard wire[payloadEnd] == 13, wire[wire.index(after: payloadEnd)] == 10 else {
                    throw DecodeError.invalidHTTP
                }
                body.append(wire[payloadStart..<payloadEnd])
                wire.removeSubrange(..<wire.index(payloadEnd, offsetBy: 2))
                if body.count > 1024 * 1024 { throw DecodeError.tooLarge }
            }
            if wire.count > 1024 * 1024 { throw DecodeError.tooLarge }
        } else {
            body.append(wire)
            wire.removeAll(keepingCapacity: true)
        }
        if body.count > 1024 * 1024 { throw DecodeError.tooLarge }
        var relevant = 0
        while let end = body.firstIndex(of: 10) {
            let line = Data(body[..<end])
            body.removeSubrange(..<body.index(after: end))
            guard !line.isEmpty,
                  let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            let type = ((event["Type"] ?? event["type"]) as? String ?? "").lowercased()
            if Self.relevantKinds.contains(type) { relevant += 1 }
        }
        return relevant
    }
}

final class MobyDockerEventMonitor {
    private var task: Task<Void, Never>?

    func start(onEvent: @escaping () -> Void) {
        guard task == nil else { return }
        task = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                do { try Self.streamEvents(onEvent: onEvent) }
                catch { /* VM booting, daemon stopped or event socket reconnecting */ }
                if Task.isCancelled { return }
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private static func streamEvents(onEvent: () -> Void) throws {
        let fd = try DockerUnixHTTP.connect(MobyPaths.socket.path, timeout: 5)
        defer { Darwin.close(fd) }
        try DockerUnixHTTP.send(fd, Data(
            "GET /events HTTP/1.1\r\nHost: docker\r\nAccept: application/json\r\nConnection: close\r\n\r\n".utf8))
        var decoder = MobyDockerEventStreamDecoder()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while !Task<Never, Never>.isCancelled {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let rc = Darwin.poll(&pfd, 1, 800)
            if rc == 0 || (rc < 0 && errno == EINTR) { continue }
            guard rc > 0, (pfd.revents & Int16(POLLIN)) != 0 else { return }
            let n = Darwin.read(fd, &buffer, buffer.count)
            guard n > 0 else { return }
            let count = try decoder.append(Data(buffer.prefix(n)))
            if count > 0 { onEvent() }
        }
    }
}
