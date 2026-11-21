// Native macOS Moby control plane. No Rust CLI, HTTP server, or Docker context mutation.
// All Docker HTTP traffic is over ~/.kiri-moby/run/docker.sock.
import AppKit
import Darwin
import Foundation

enum MobyRuntimeError: LocalizedError {
    case failure(String)
    var errorDescription: String? {
        if case .failure(let message) = self { return message }
        return "Moby operation failed"
    }
}
private func fail(_ message: String) -> MobyRuntimeError { .failure(message) }

enum MobyPaths {
    static var data: URL {
        if let override = ProcessInfo.processInfo.environment["KIRI_MOBY_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kiri-moby", isDirectory: true)
    }
    static var socket: URL { data.appendingPathComponent("run/docker.sock") }
    static var control: URL { data.appendingPathComponent("run/host-control.sock") }
    static var resources: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true) }
    static var docker: URL { resources.appendingPathComponent("bin/docker") }
}

private struct DockerResponse {
    let status: Int
    let body: Data
    var json: Any {
        (try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])) ?? NSNull()
    }
    func requireSuccess() throws -> Any {
        guard (200..<300).contains(status) else {
            let message = (json as? [String: Any])?["message"] as? String ??
                String(data: body, encoding: .utf8) ?? "Docker error"
            throw fail("Docker HTTP \(status): \(message)")
        }
        return json
    }
}

// The only raw socket implementation in the macOS GUI. It bounds response size,
// handles HTTP/1.1 framing and chunked bodies, and never opens a TCP listener.
private enum DockerUnixHTTP {
    static func connect(_ path: String, timeout: TimeInterval) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw fail("Unix socket: \(String(cString: strerror(errno)))") }
        do {
            let name = Array(path.utf8CString)
            guard name.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
                throw fail("Unix socket path is too long")
            }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutablePointer(to: &address.sun_path) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: name.count) { dest in
                    for (i, byte) in name.enumerated() { dest[i] = byte }
                }
            }
            let rc = withUnsafePointer(to: &address) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard rc == 0 else { throw fail("Connect \(path): \(String(cString: strerror(errno)))") }
            var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
            _ = withUnsafePointer(to: &tv) {
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
            }
            _ = withUnsafePointer(to: &tv) {
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
            }
            var noSignal: Int32 = 1
            _ = withUnsafePointer(to: &noSignal) {
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    static func send(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let n = Darwin.write(fd, base.advanced(by: written), buffer.count - written)
                if n > 0 { written += n; continue }
                if n < 0 && errno == EINTR { continue }
                throw fail("Write Docker socket: \(String(cString: strerror(errno)))")
            }
        }
    }

    private static func readAll(_ fd: Int32, maxBytes: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while result.count <= maxBytes {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n == 0 { return result }
            if n < 0 && errno == EINTR { continue }
            if n < 0 { throw fail("Read Docker socket: \(String(cString: strerror(errno)))") }
            result.append(contentsOf: buffer.prefix(n))
        }
        throw fail("Docker response exceeds \(maxBytes) bytes")
    }

    private static func unchunk(_ input: Data, limit: Int) throws -> Data {
        let bytes = [UInt8](input)
        var index = 0
        var output = Data()
        while index < bytes.count {
            guard let lineEnd = bytes[index...].firstIndex(of: 10) else { throw fail("Truncated chunk header") }
            let line = String(decoding: bytes[index..<lineEnd], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let size = Int(line.split(separator: ";", maxSplits: 1)[0], radix: 16), size >= 0 else {
                throw fail("Invalid chunk size")
            }
            index = lineEnd + 1
            if size == 0 { return output }
            guard size <= limit - output.count, index + size + 2 <= bytes.count else {
                throw fail("Truncated or oversized chunk")
            }
            output.append(contentsOf: bytes[index..<(index + size)])
            index += size
            guard bytes[index] == 13 && bytes[index + 1] == 10 else { throw fail("Malformed chunk delimiter") }
            index += 2
        }
        throw fail("Missing final HTTP chunk")
    }

    static func request(_ method: String, _ path: String, body: Any? = nil, timeout: TimeInterval = 120, maxBytes: Int = 24 * 1024 * 1024) throws -> DockerResponse {
        let fd = try connect(MobyPaths.socket.path, timeout: timeout)
        defer { Darwin.close(fd) }
        let payload = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let header = "\(method) \(path) HTTP/1.1\r\nHost: docker\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\n\r\n"
        try send(fd, Data(header.utf8))
        if !payload.isEmpty { try send(fd, payload) }
        let response = try readAll(fd, maxBytes: maxBytes + 16384)
        guard let boundary = response.range(of: Data("\r\n\r\n".utf8)) else { throw fail("Invalid Docker HTTP response") }
        let headerBytes = response[..<boundary.lowerBound]
        let headers = String(decoding: headerBytes, as: UTF8.self).components(separatedBy: "\r\n")
        guard let statusToken = headers.first?.split(separator: " ").dropFirst().first,
              let status = Int(statusToken) else { throw fail("Invalid Docker HTTP status") }
        let fields = Dictionary(headers.dropFirst().compactMap { line -> (String, String)? in
            guard let ix = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<ix]).lowercased(), String(line[line.index(after: ix)...]).trimmingCharacters(in: .whitespaces))
        }, uniquingKeysWith: { _, new in new })
        let bytes = response[boundary.upperBound...]
        let data: Data
        if fields["transfer-encoding"]?.lowercased().contains("chunked") == true {
            data = try unchunk(Data(bytes), limit: maxBytes)
        } else if let length = fields["content-length"].flatMap(Int.init) {
            guard length <= maxBytes, bytes.count >= length else { throw fail("Incomplete Docker body") }
            data = Data(bytes.prefix(length))
        } else {
            guard bytes.count <= maxBytes else { throw fail("Docker body exceeds limit") }
            data = Data(bytes)
        }
        return DockerResponse(status: status, body: data)
    }

    static func ping() -> Bool {
        (try? request("GET", "/_ping", timeout: 1).status) == 200
    }
}

private func dockerPath(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters:
        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/@")) ?? ""
}
private func number(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue
}
private func integer(_ value: Any?) -> Int64? {
    (value as? NSNumber)?.int64Value
}
private func dict(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
private func get(_ value: Any?, _ keys: String...) -> Any? {
    keys.reduce(value) { current, key in (current as? [String: Any])?[key] }
}
private func jsonValue(_ value: Any?) -> Any { value ?? NSNull() }

private enum MobyConfig {
    static let fm = FileManager.default
    static var cpus: Int { min(16, max(1, ProcessInfo.processInfo.activeProcessorCount)) }
    static var memory: Int {
        let total = Int(ProcessInfo.processInfo.physicalMemory / 1048576)
        let maximum = min(max(1024, total - 1024), total * 3 / 4, 65536)
        return max(1024, maximum / 256 * 256)
    }
    static func ensurePrivate(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    static func readResources() throws -> [String: Int] {
        let url = MobyPaths.data.appendingPathComponent("vm-resources.json")
        let values: [String: Int]
        if fm.fileExists(atPath: url.path) {
            let raw = try Data(contentsOf: url)
            guard let decoded = try JSONSerialization.jsonObject(with: raw) as? [String: Int] else {
                throw fail("Invalid VM resource settings")
            }
            values = decoded
        } else {
            values = ["cpus": min(4, cpus), "memory_mib": min(4096, memory)]
        }
        try validate(cpu: values["cpus"] ?? -1, memory: values["memory_mib"] ?? -1)
        return values
    }
    static func validate(cpu: Int, memory size: Int) throws {
        guard (1...cpus).contains(cpu), (1024...memory).contains(size), size % 256 == 0 else {
            throw fail("VM requires 1-\(cpus) CPUs, 1024-\(memory) MiB, memory in 256 MiB steps")
        }
    }
    static func saveResources(_ config: [String: Int]) throws {
        try ensurePrivate(MobyPaths.data)
        let url = MobyPaths.data.appendingPathComponent("vm-resources.json")
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func allowedShare(_ path: String) -> Bool {
        guard (path.hasPrefix("/Users/") || path.hasPrefix("/Volumes/")),
              !path.contains("//"), !path.contains("/./"), !path.contains(","),
              !path.components(separatedBy: "/").contains("..") else { return false }
        return path.split(separator: "/").count >= 3
    }
    static func shares() throws -> [String] {
        let url = MobyPaths.data.appendingPathComponent("authorized-shares.json")
        guard fm.fileExists(atPath: url.path) else { return [] }
        let raw = try Data(contentsOf: url)
        guard let values = try JSONSerialization.jsonObject(with: raw) as? [String],
              values.count <= 16, Set(values).count == values.count,
              values.allSatisfy(allowedShare) else { throw fail("Invalid authorized shared folders") }
        return values
    }
    static func setShares(_ value: [String]) throws {
        guard value.count <= 16, Set(value).count == value.count,
              value.allSatisfy(allowedShare) else { throw fail("Unsafe shared folders") }
        try ensurePrivate(MobyPaths.data)
        let url = MobyPaths.data.appendingPathComponent("authorized-shares.json")
        try JSONSerialization.data(withJSONObject: value).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private enum MobyVM {
    static let fm = FileManager.default
    static func control(_ command: String) throws -> [String: Any] {
        let fd = try DockerUnixHTTP.connect(MobyPaths.control.path, timeout: 2)
        defer { Darwin.close(fd) }
        try DockerUnixHTTP.send(fd, Data(command.utf8))
        var buffer = [UInt8](repeating: 0, count: 1024)
        let n = Darwin.read(fd, &buffer, buffer.count)
        guard n > 0 else { throw fail("VM control socket did not respond") }
        let reply = Data(buffer.prefix(n))
        if command == "STOP\n" {
            guard reply == Data("OK\n".utf8) else { throw fail("VM rejected stop") }
            return ["message": "VM stop requested"]
        }
        guard let info = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw fail("Invalid VM control response")
        }
        return info
    }

    static func stat() -> Any {
        (try? control("STAT\n")) ?? NSNull()
    }

    static func installGuestAssets() throws {
        let source = MobyPaths.resources.appendingPathComponent("guest")
        guard fm.fileExists(atPath: source.path) else { return }
        try MobyConfig.ensurePrivate(MobyPaths.data)
        let target = MobyPaths.data.appendingPathComponent("guest")
        let files = ["Image", "initramfs.cpio", "data.img.tgz",
                     "system.img.tgz", "rootfs.revision", "SHA256SUMS"]
        let revisionFile = MobyPaths.resources.appendingPathComponent("SOURCE_REVISION")
        guard let revision = try? String(contentsOf: revisionFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines) else {
            try MobyConfig.ensurePrivate(target)
            for file in files where !fm.fileExists(atPath: target.appendingPathComponent(file).path) {
                let sourceFile = source.appendingPathComponent(file)
                if fm.fileExists(atPath: sourceFile.path) {
                    try fm.copyItem(at: sourceFile, to: target.appendingPathComponent(file))
                }
            }
            return
        }
        guard revision.count == 40, revision.utf8.allSatisfy({
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) || ($0 >= 65 && $0 <= 70)
        }) else { throw fail("Invalid signed Guest SOURCE_REVISION") }
        let lockPath = MobyPaths.data.appendingPathComponent("moby-vm.lock").path
        let lockFD = Darwin.open(lockPath, O_CREAT | O_RDWR, mode_t(0o600))
        guard lockFD >= 0 else { throw fail("Guest lock could not be opened") }
        defer { Darwin.close(lockFD) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw fail("VM owns the disk; Guest assets cannot be replaced while running")
        }
        defer { flock(lockFD, LOCK_UN) }
        var isLink = ObjCBool(false)
        if fm.fileExists(atPath: target.path, isDirectory: &isLink) {
            let attributes = try fm.attributesOfItem(atPath: target.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw fail("Refusing to replace Guest asset symlink")
            }
        }
        if let old = try? String(contentsOf: target.appendingPathComponent("SOURCE_REVISION"), encoding: .utf8),
           old.trimmingCharacters(in: .whitespacesAndNewlines) == revision,
           files.allSatisfy({ fm.fileExists(atPath: target.appendingPathComponent($0).path) }) { return }
        guard files.allSatisfy({ fm.fileExists(atPath: source.appendingPathComponent($0).path) }) else {
            throw fail("Signed App lacks a required Guest asset")
        }
        let stage = MobyPaths.data.appendingPathComponent(".guest-staging-\(getpid())")
        guard !fm.fileExists(atPath: stage.path) else { throw fail("Previous partial Guest stage exists") }
        try MobyConfig.ensurePrivate(stage)
        for file in files { try fm.copyItem(at: source.appendingPathComponent(file), to: stage.appendingPathComponent(file)) }
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        verify.arguments = ["-a", "256", "-c", "SHA256SUMS"]
        verify.currentDirectoryURL = stage
        verify.standardOutput = FileHandle.nullDevice
        verify.standardError = FileHandle.nullDevice
        try verify.run()
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else { throw fail("Guest SHA256SUMS verification failed") }
        try Data("\(revision)\n".utf8).write(to: stage.appendingPathComponent("SOURCE_REVISION"))
        let backup = MobyPaths.data.appendingPathComponent("guest-backup-\(revision)-\(getpid())")
        guard !fm.fileExists(atPath: backup.path) else { throw fail("Guest backup path already exists") }
        let oldExists = fm.fileExists(atPath: target.path)
        if oldExists { try fm.moveItem(at: target, to: backup) }
        do { try fm.moveItem(at: stage, to: target) }
        catch {
            if oldExists { try? fm.moveItem(at: backup, to: target) }
            throw error
        }
    }

    private static func vmDiskIsLocked() -> Bool {
        // The same flock protocol is used by the standalone Host and asset updater.
        let path = MobyPaths.data.appendingPathComponent("moby-vm.lock").path
        let fd = Darwin.open(path, O_RDWR)
        if fd < 0 { return false }
        defer { Darwin.close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(fd, LOCK_UN)
            return false
        }
        return true
    }

    static func start() throws {
        if DockerUnixHTTP.ping() { return }
        // A second GUI may open while the first Host is booting. Reuse it instead
        // of racing a new Helper for the same ext4 writable disk.
        if vmDiskIsLocked() {
            for _ in 0..<160 {
                if DockerUnixHTTP.ping() { return }
                if !vmDiskIsLocked() { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            if vmDiskIsLocked() {
                throw fail("An existing Kiri Moby Host owns the VM disk but Docker did not become ready")
            }
        }
        try installGuestAssets()
        // A signed Swift GUI must launch only its bundled Swift Host; no stale Rust fallback.
        // Launch a nested, independently signed headless Helper, without
        // changing the VM protocol or the macOS-owned Virtualization XPC worker.
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/Helpers/Kiri Moby Helper.app/Contents/MacOS/Kiri Moby Helper")
        guard fm.isExecutableFile(atPath: helper.path) else {
            throw fail("Signed Kiri Moby Helper.app is missing from the app")
        }
        let cpus = try MobyConfig.readResources()
        try MobyConfig.ensurePrivate(MobyPaths.data.appendingPathComponent("logs"))
        let log = MobyPaths.data.appendingPathComponent("logs/gui-host.log")
        if !fm.fileExists(atPath: log.path) { _ = fm.createFile(atPath: log.path, contents: nil) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
        let output = try FileHandle(forWritingTo: log)
        _ = try output.seekToEnd()
        let proc = Process()
        proc.executableURL = helper
        var env = ProcessInfo.processInfo.environment
        for key in ["KIRI_MOBY_SHARE_MAC", "KIRI_MOBY_SHARE_DIRS", "KIRI_MOBY_TCP_PORTS", "KIRI_MOBY_DISABLE_PORT_FORWARD"] {
            env.removeValue(forKey: key)
        }
        env["KIRI_MOBY_DATA_DIR"] = MobyPaths.data.path
        env["KIRI_MOBY_CPUS"] = String(cpus["cpus"] ?? 4)
        env["KIRI_MOBY_MEMORY_MIB"] = String(cpus["memory_mib"] ?? 4096)
        let shares = try MobyConfig.shares()
        if !shares.isEmpty { env["KIRI_MOBY_SHARE_DIRS"] = shares.joined(separator: ",") }
        proc.environment = env
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = output
        proc.standardError = output
        try proc.run()
        for _ in 0..<160 {
            if DockerUnixHTTP.ping() { return }
            if !proc.isRunning { throw fail("Kiri Moby Host exited; inspect \(log.path)") }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw fail("Moby VM did not become ready; inspect \(log.path)")
    }

    static func stop() throws {
        // Do not confuse a crashed/not-yet-ready dockerd with a stopped VM.
        // The Host must remain stoppable even if its Docker API is unavailable.
        if !vmDiskIsLocked() && !DockerUnixHTTP.ping() { return }
        for _ in 0..<40 {
            if fm.fileExists(atPath: MobyPaths.control.path) { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard fm.fileExists(atPath: MobyPaths.control.path) else {
            throw fail("VM still owns its data disk, but the Host control socket is unavailable")
        }
        _ = try control("STOP\n")
        for _ in 0..<160 {
            if !vmDiskIsLocked() && !DockerUnixHTTP.ping() { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw fail("Moby VM shutdown did not release its data disk")
    }
}

enum MobyRuntime {
    private static func docker(_ args: [String]) throws -> String {
        // Never fall back to another user's Docker CLI, context, or arbitrary PATH.
        let executable = MobyPaths.docker
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw fail("Bundled Docker CLI is missing from Kiri Moby.app")
        }
        let task = Process()
        task.executableURL = executable
        task.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["DOCKER_HOST"] = "unix://\(MobyPaths.socket.path)"
        env.removeValue(forKey: "DOCKER_CONTEXT")
        task.environment = env
        let stdout = Pipe(), stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        try task.run()
        // Read pipes concurrently to prevent stderr/stdout pipe-buffer deadlocks.
        let errLock = NSLock()
        var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let bytes = stderr.fileHandleForReading.readDataToEndOfFile()
            errLock.lock()
            errorData = bytes
            errLock.unlock()
            group.leave()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        task.waitUntilExit()
        let msg = String(decoding: (output + errorData).prefix(60_000), as: UTF8.self)
        guard task.terminationStatus == 0 else { throw fail("Docker CLI exited \(task.terminationStatus): \(msg)") }
        return msg
    }

    private static func dockerJSON(_ path: String, timeout: TimeInterval = 120) throws -> Any {
        try DockerUnixHTTP.request("GET", path, timeout: timeout).requireSuccess()
    }
    private static func require(_ method: String, _ path: String, _ body: Any? = nil) throws -> Any {
        try DockerUnixHTTP.request(method, path, body: body).requireSuccess()
    }
    private static func decodeLogs(_ bytes: Data) -> String {
        let raw = [UInt8](bytes)
        var output = [UInt8]()
        var offset = 0
        while offset + 8 <= raw.count && [1, 2, 3].contains(raw[offset]) &&
              raw[(offset + 1)..<(offset + 4)].allSatisfy({ $0 == 0 }) {
            let length = raw[(offset + 4)..<(offset + 8)].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= raw.count - offset - 8 else { break }
            output.append(contentsOf: raw[(offset + 8)..<(offset + 8 + length)])
            offset += 8 + length
        }
        return String(decoding: (offset == 0 ? raw : output).prefix(240_000), as: UTF8.self)
    }
    private static func summarize(_ doc: Any) -> [String: Any] {
        let cpu = number(get(doc, "cpu_stats", "cpu_usage", "total_usage"))
        let previousCPU = number(get(doc, "precpu_stats", "cpu_usage", "total_usage"))
        let system = number(get(doc, "cpu_stats", "system_cpu_usage"))
        let previousSystem = number(get(doc, "precpu_stats", "system_cpu_usage"))
        let cores = number(get(doc, "cpu_stats", "online_cpus")) ?? 1
        var percent: Double?
        if let cpu, let previousCPU, let system, let previousSystem,
           cpu >= previousCPU, system > previousSystem {
            percent = (cpu - previousCPU) / (system - previousSystem) * max(cores, 1) * 100
        }
        let memoryRaw = integer(get(doc, "memory_stats", "usage"))
        let cached = integer(get(doc, "memory_stats", "stats", "inactive_file")) ??
                     integer(get(doc, "memory_stats", "stats", "total_inactive_file")) ?? 0
        let used = memoryRaw.map { max(0, $0 - cached) }
        let limit = integer(get(doc, "memory_stats", "limit")).flatMap { $0 > 0 ? $0 : nil }
        var rx: Int64 = 0, tx: Int64 = 0, readBytes: Int64 = 0, writeBytes: Int64 = 0
        for item in dict(get(doc, "networks")).values {
            rx += integer(get(item, "rx_bytes")) ?? 0
            tx += integer(get(item, "tx_bytes")) ?? 0
        }
        for item in get(doc, "blkio_stats", "io_service_bytes_recursive") as? [[String: Any]] ?? [] {
            let count = integer(item["value"]) ?? 0
            switch (item["op"] as? String)?.lowercased() {
            case "read": readBytes += count
            case "write": writeBytes += count
            default: break
            }
        }
        return ["cpu_percent": jsonValue(percent),
                "memory_bytes": jsonValue(used),
                "memory_limit_bytes": jsonValue(limit),
                "memory_percent": jsonValue((used != nil && limit != nil) ?
                    min(100, max(0, Double(used!) / Double(limit!) * 100)) : nil),
                "net_rx_bytes": rx, "net_tx_bytes": tx,
                "block_read_bytes": readBytes, "block_write_bytes": writeBytes,
                "pids": jsonValue(integer(get(doc, "pids_stats", "current")))]
    }
    private static func stats() throws -> [String: Any] {
        guard DockerUnixHTTP.ping() else { return ["stats": [:], "truncated": false] }
        let list = try dockerJSON("/containers/json?all=0", timeout: 5) as? [[String: Any]] ?? []
        let ids = list.filter { ($0["State"] as? String) == "running" }
            .compactMap { $0["Id"] as? String }
            .filter { !$0.isEmpty && $0.count <= 64 && $0.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }}
        let truncated = ids.count > 64
        let selected = Array(ids.prefix(64))
        let lock = NSLock()
        var result: [String: Any] = [:]
        if !selected.isEmpty {
            DispatchQueue.concurrentPerform(iterations: min(6, selected.count)) { worker in
                var index = worker
                while index < selected.count {
                    let id = selected[index]
                    if let raw = try? dockerJSON("/containers/\(dockerPath(id))/stats?stream=false", timeout: 5) {
                        lock.lock()
                        result[id] = summarize(raw)
                        lock.unlock()
                    }
                    index += 6
                }
            }
        }
        return ["stats": result, "truncated": truncated]
    }
    private static func snapshot() throws -> [String: Any] {
        let settings = try MobyConfig.readResources()
        let vmConfig: [String: Any] = ["cpus": settings["cpus"] ?? 4,
                                       "memory_mib": settings["memory_mib"] ?? 4096,
                                       "max_cpus": MobyConfig.cpus,
                                       "max_memory_mib": MobyConfig.memory]
        let shares = try MobyConfig.shares()
        guard DockerUnixHTTP.ping() else {
            return ["online": false, "containers": [], "images": [],
                    "volumes": [], "networks": [], "shares": shares,
                    "memory": NSNull(), "vm_config": vmConfig]
        }
        let volumes = try dockerJSON("/volumes")
        return ["online": true, "containers": try dockerJSON("/containers/json?all=1"),
                "images": try dockerJSON("/images/json"),
                "volumes": dict(volumes)["Volumes"] ?? [],
                "networks": try dockerJSON("/networks"),
                "info": try dockerJSON("/info"), "version": try dockerJSON("/version"),
                "memory": MobyVM.stat(), "shares": shares, "vm_config": vmConfig]
    }
    private static func action(_ value: [String: Any]) throws -> String {
        let kind = value["action"] as? String ?? ""
        let id = value["id"] as? String ?? ""
        let name = value["name"] as? String ?? ""
        let path = value["path"] as? String ?? ""
        switch kind {
        case "inspect":
            let type = value["kind"] as? String ?? "containers"
            guard ["containers", "images", "volumes", "networks"].contains(type) else { throw fail("Unknown inspect type") }
            let endpoint = type == "containers" || type == "images" ? "/\(type)/\(dockerPath(id))/json"
                : "/\(type)/\(dockerPath(id))"
            let obj = try dockerJSON(endpoint)
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
            return String(decoding: data, as: UTF8.self)
        case "logs":
            let requested = Int(value["tail"] as? String ?? "200") ?? 200
            let tail = max(10, min(5000, requested))
            let response = try DockerUnixHTTP.request("GET",
                "/containers/\(dockerPath(id))/logs?stdout=1&stderr=1&tail=\(tail)&timestamps=1",
                maxBytes: 8 * 1024 * 1024)
            _ = try response.requireSuccess()
            return decodeLogs(response.body)
        case "authorize_share":
            guard MobyConfig.allowedShare(path), FileManager.default.fileExists(atPath: path) else {
                throw fail("Share must be an existing project folder under /Users or /Volumes")
            }
            var shares = try MobyConfig.shares()
            if shares.contains(path) { return "Directory already authorized" }
            shares.append(path)
            try MobyConfig.setShares(shares)
            return "Directory authorized; restart VM to apply"
        case "remove_share":
            let previous = try MobyConfig.shares()
            guard previous.contains(path) else { throw fail("Share not found") }
            try MobyConfig.setShares(previous.filter { $0 != path })
            return "Authorization revoked; restart VM to apply"
        case "apply_shares":
            if DockerUnixHTTP.ping() { try MobyVM.stop() }
            try MobyVM.start()
            return "Shared folders applied; Moby VM restarted"
        case "exec":
            let command = value["command"] as? String ?? ""
            guard !id.isEmpty, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw fail("Container and nonempty command required")
            }
            return try docker(["exec", id, "sh", "-c", command])
        case "create_volume":
            let result = try require("POST", "/volumes/create", ["Name": name])
            return "Volume created: \(dict(result)["Name"] ?? name)"
        case "create_network":
            let result = try require("POST", "/networks/create", ["Name": name, "Driver": "bridge"])
            return "Network created: \(dict(result)["Id"] ?? name)"
        case "compose_up", "compose_down", "compose_ps", "compose_logs":
            guard (path.hasSuffix(".yml") || path.hasSuffix(".yaml")),
                  FileManager.default.fileExists(atPath: path) else { throw fail("Select an existing Compose YAML file") }
            switch kind {
            case "compose_up": return try docker(["compose", "-f", path, "up", "-d"])
            case "compose_down": return try docker(["compose", "-f", path, "down"])
            case "compose_logs": return try docker(["compose", "-f", path, "logs", "--no-color", "--tail", "200"])
            default: return try docker(["compose", "-f", path, "ps"])
            }
        case "build":
            let platform = value["platform"] as? String ?? "linux/arm64"
            guard ["linux/arm64", "linux/amd64"].contains(platform),
                  !name.isEmpty, FileManager.default.fileExists(atPath: path) else {
                throw fail("Buildx needs a valid context, tag, and supported platform")
            }
            return try docker(["buildx", "build", "--platform", platform, "--load", "-t", name, path])
        case "open_local":
            guard let url = URL(string: value["url"] as? String ?? ""),
                  url.scheme == "http", url.host == "127.0.0.1",
                  (url.port ?? 0) > 0 else { throw fail("Only 127.0.0.1 published ports may be opened") }
            // NSWorkspace uses LaunchServices directly; no short-lived /usr/bin/open helper.
            let success: Bool
            if Thread.isMainThread {
                success = NSWorkspace.shared.open(url)
            } else {
                success = DispatchQueue.main.sync { NSWorkspace.shared.open(url) }
            }
            guard success else { throw fail("macOS could not open \(url.absoluteString)") }
            return "Opened \(url.absoluteString)"
        default:
            throw fail("Unsupported native Docker operation: \(kind)")
        }
    }

    private static func run(_ args: [String]) throws -> [String: Any] {
        guard let operation = args.first else { throw fail("Missing Moby operation") }
        func argument(_ index: Int) throws -> String {
            guard args.indices.contains(index) else { throw fail("Missing argument \(index)") }
            return args[index]
        }
        switch operation {
        case "snapshot": return try snapshot()
        case "stats": return try stats()
        case "start":
            try MobyVM.start()
            return ["message": "Moby VM started"]
        case "stop":
            try MobyVM.stop()
            return ["message": "VM stopped; Docker disk synced"]
        case "restart":
            if DockerUnixHTTP.ping() { try MobyVM.stop() }
            try MobyVM.start()
            return ["message": "Moby VM restarted"]
        case "configure":
            guard let cpu = Int(try argument(1)), let memory = Int(try argument(2)) else {
                throw fail("Invalid VM CPU or RAM")
            }
            try MobyConfig.validate(cpu: cpu, memory: memory)
            let apply = try argument(3)
            guard ["apply", "save"].contains(apply) else { throw fail("Expected apply or save") }
            try MobyConfig.saveResources(["cpus": cpu, "memory_mib": memory])
            let active = DockerUnixHTTP.ping()
            let live = dict(MobyVM.stat())
            let info = active ? (try? dockerJSON("/info")) : nil
            let pending = active && (integer(live["vm_memory_ceiling_mib"]) != Int64(memory)
                || integer(get(info, "NCPU")) != Int64(cpu))
            if apply == "apply" && pending { try MobyVM.stop(); try MobyVM.start() }
            return ["message": apply == "apply" && pending ? "VM restarted with configured resources"
                : active && pending ? "Settings saved; VM restart required"
                : "VM CPU and memory settings saved"]
        case "pull": return ["message": try docker(["pull", argument(1)])]
        case "run":
            let image = try argument(1)
            let created = try require("POST", "/containers/create",
                                      ["Image": image, "Env": [], "HostConfig": ["PublishAllPorts": true]])
            guard let id = dict(created)["Id"] as? String else { throw fail("Docker did not return container ID") }
            _ = try require("POST", "/containers/\(dockerPath(id))/start")
            return ["message": "Container started: \(id.prefix(12))"]
        case "rmi":
            _ = try require("DELETE", "/images/\(dockerPath(argument(1)))")
            return ["message": "Image removed"]
        case "rmvol":
            _ = try require("DELETE", "/volumes/\(dockerPath(argument(1)))")
            return ["message": "Volume removed"]
        case "rmnet":
            _ = try require("DELETE", "/networks/\(dockerPath(argument(1)))")
            return ["message": "Network removed"]
        case "container":
            let verb = try argument(1), id = try argument(2)
            guard ["remove", "start", "stop", "restart", "pause", "unpause"].contains(verb) else {
                throw fail("Unsupported container action")
            }
            let base = "/containers/\(dockerPath(id))"
            _ = try require(verb == "remove" ? "DELETE" : "POST",
                            verb == "remove" ? base + "?force=1" : base + "/" + verb)
            return ["message": "\(verb): \(id.prefix(12))"]
        case "action":
            let raw = Data(try argument(1).utf8)
            guard let value = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                throw fail("Invalid native action JSON")
            }
            return ["message": try action(value)]
        default: throw fail("Unsupported Moby command: \(operation)")
        }
    }

    static func request(_ args: [String]) throws -> Data {
        let result: [String: Any]
        do {
            var response = try run(args)
            response["ok"] = true
            result = response
        } catch {
            result = ["ok": false, "error": error.localizedDescription]
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
    }

    static func terminalEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["DOCKER_HOST"] = "unix://\(MobyPaths.socket.path)"
        env["TERM"] = "xterm-256color"
        env.removeValue(forKey: "DOCKER_CONTEXT")
        return env
    }
}
