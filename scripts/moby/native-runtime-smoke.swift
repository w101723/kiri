// Integration smoke test for the real in-process Swift Docker HTTP-over-UDS client.
// A tiny local fake dockerd sends actual HTTP framing, including chunked data.
// It never starts or modifies a real VM, Docker daemon or external context.
import Darwin
import Foundation

@main
enum NativeRuntimeSmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiri-moby-uds-test-\(getpid())", isDirectory: true)
        let run = root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("KIRI_MOBY_DATA_DIR", root.path, 1)
        let path = run.appendingPathComponent("docker.sock").path
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { fatalError("socket: \(errno)") }
        defer { Darwin.close(listener) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let chars = Array(path.utf8CString)
        guard chars.count <= MemoryLayout.size(ofValue: addr.sun_path) else { fatalError("socket path too long") }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: chars.count) { target in
                for index in chars.indices { target[index] = chars[index] }
            }
        }
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0, Darwin.listen(listener, 16) == 0 else { fatalError("bind/listen: \(errno)") }
        let served = DispatchSemaphore(value: 0)
        let requests = NSLock()
        var seen: [String] = []
        let expected = 12
        DispatchQueue.global(qos: .utility).async {
            for _ in 0..<expected {
                let fd = Darwin.accept(listener, nil, nil)
                guard fd >= 0 else { break }
                var incoming = [UInt8](repeating: 0, count: 4096)
                let count = incoming.withUnsafeMutableBytes {
                    Darwin.read(fd, $0.baseAddress, $0.count)
                }
                guard count > 0 else { Darwin.close(fd); break }
                let header = String(decoding: incoming.prefix(count), as: UTF8.self)
                let firstLine = header.components(separatedBy: "\r\n").first ?? ""
                let pieces = firstLine.split(separator: " ")
                let route = pieces.count > 1 ? String(pieces[1]) : "INVALID"
                requests.lock()
                seen.append(firstLine)
                requests.unlock()
                var status = 200
                var payload = "{}"
                switch route {
                case "/_ping": payload = "OK"
                case "/containers/json?all=1":
                    payload = #"[{"Id":"a000000000000000","Names":["/nginx"],"Image":"nginx","State":"running"}]"#
                case "/containers/json?all=0":
                    payload = #"[{"Id":"a000000000000000","State":"running"}]"#
                case "/containers/a000000000000000/stats?stream=false":
                    payload = #"{"cpu_stats":{"cpu_usage":{"total_usage":1250},"system_cpu_usage":11000,"online_cpus":4},"precpu_stats":{"cpu_usage":{"total_usage":1000},"system_cpu_usage":10000},"memory_stats":{"usage":536870912,"limit":1073741824,"stats":{"inactive_file":134217728}},"networks":{"eth0":{"rx_bytes":1024,"tx_bytes":2048}},"pids_stats":{"current":7}}"#
                case "/images/json": payload = #"[]"#
                case "/volumes": payload = #"{"Volumes":[]}"#
                case "/networks": payload = #"[]"#
                case "/info": payload = #"{"NCPU":4,"MemTotal":4294967296}"#
                case "/version": payload = #"{"Version":"29.0.0"}"#
                case "/containers/a000000000000000/start":
                    status = 204
                    payload = ""
                case "/images/missing":
                    status = 404
                    payload = #"{"message":"No such image"}"#
                default:
                    status = 404
                    payload = #"{"message":"unexpected endpoint"}"#
                }
                // Prove Docker chunked framing is decoded correctly on /images.
                let raw: String
                if route == "/images/json" {
                    let size = String(payload.utf8.count, radix: 16)
                    raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n\(size)\r\n\(payload)\r\n0\r\n\r\n"
                } else {
                    raw = "HTTP/1.1 \(status) Mock\r\nContent-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n\(payload)"
                }
                let bytes = Array(raw.utf8)
                bytes.withUnsafeBytes { buffer in
                    var sent = 0
                    while sent < buffer.count {
                        let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                        guard n > 0 else { break }
                        sent += n
                    }
                }
                Darwin.close(fd)
            }
            served.signal()
        }
        func response(_ args: [String]) throws -> [String: Any] {
            let data = try MobyRuntime.request(args)
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "Smoke", code: 1)
            }
            return value
        }
        let snapshot = try response(["snapshot"])
        guard snapshot["ok"] as? Bool == true, snapshot["online"] as? Bool == true,
              (snapshot["containers"] as? [[String: Any]])?.count == 1,
              (snapshot["images"] as? [[String: Any]])?.isEmpty == true else {
            fatalError("Snapshot or chunked Docker response invalid: \(snapshot)")
        }
        let stats = try response(["stats"])
        let results = stats["stats"] as? [String: [String: Any]]
        let sample = results?["a000000000000000"]
        guard stats["ok"] as? Bool == true,
              sample?["pids"] as? Int == 7,
              sample?["memory_bytes"] as? Int == 402653184 else {
            fatalError("Native Docker stats normalization invalid: \(stats)")
        }
        let started = try response(["container", "start", "a000000000000000"])
        guard started["ok"] as? Bool == true else { fatalError("Docker start failed") }
        let missing = try response(["rmi", "missing"])
        guard missing["ok"] as? Bool == false,
              (missing["error"] as? String)?.contains("No such image") == true else {
            fatalError("Docker error response not propagated")
        }
        guard served.wait(timeout: .now() + 5) == .success else { fatalError("Mock dockerd did not finish") }
        requests.lock()
        let received = seen
        requests.unlock()
        guard received.count == expected else {
            fatalError("Expected \(expected) API requests, saw \(received.count): \(received)")
        }
        print("PASS: native Swift Docker UDS snapshot/stats/chunked/errors/operations (\(expected) real socket requests)")
    }
}
