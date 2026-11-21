import Darwin
import Foundation

// libkrun runs one VM per Helper process and calls _exit after guest poweroff.
// The disk lock is held until process exit, including the forced-stop path.
@main
private final class HVFHelper {
    private let data = MobyPaths.data
    private let stateLock = NSLock()
    private var phase = "starting"
    private var memory: GuestMemory?
    private var ceiling: Int?
    private var signals: [DispatchSourceSignal] = []
    private let controlQueue = DispatchQueue(label: "dev.kiri.moby.hvf.control")
    private let shutdownQueue = DispatchQueue(label: "dev.kiri.moby.hvf.shutdown")
    private var stopRequestedAt: DispatchTime?
    private var portListeners: LocalListeners?

    static func main() {
        if CommandLine.arguments == [CommandLine.arguments[0], "--version"] {
            print("kiri-moby-host hvf-libkrun")
            return
        }
        _ = umask(0o077)
        _ = signal(SIGPIPE, SIG_IGN)
        do { try HVFHelper().run() }
        catch { trace("FATAL: \(error.localizedDescription)"); exit(1) }
    }

    private func readState<T>(_ body: () -> T) -> T {
        stateLock.lock(); defer { stateLock.unlock() }
        return body()
    }

    private var stopping: Bool { readState { phase == "stopping" } }
    private func socketPath(_ name: String) -> URL { data.appendingPathComponent("run/\(name)") }
    private var shutdownDisposition: URL { data.appendingPathComponent("run/forced-stop") }

    private func removeStaleSocket(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return }
            throw hostError("Cannot check \(url.path)")
        }
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else {
            throw hostError("Refusing non-socket or foreign path: \(url.path)")
        }
        // Use the errno from connect, not a ping failure: a booting endpoint
        // or a full listener backlog is not a stale socket.
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw hostError("Cannot probe \(url.path)") }
        defer { Darwin.close(fd) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var addr = sockaddr_un()
        let name = Array(url.path.utf8CString)
        guard name.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw hostError("Unix socket path too long: \(url.path)")
        }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { bytes in
            for (i, byte) in name.enumerated() { bytes[i] = UInt8(bitPattern: byte) }
        }
        let result = withUnsafePointer(to: &addr) { address in
            address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == -1, errno == ECONNREFUSED else { throw hostError("Socket is not stale: \(url.path)") }
        guard unlink(url.path) == 0 else { throw hostError("Cannot unlink \(url.path)") }
    }

    private func connect(_ name: String) throws -> VMConnection {
        VMConnection(try DockerUnixHTTP.connect(socketPath(name).path, timeout: 2))
    }

    private func processControl(_ fd: Int32) {
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var command = [UInt8](repeating: 0, count: 5)
        var offset = 0
        while offset < command.count {
            let n = command.withUnsafeMutableBytes { recv(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset, 0) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return }
            offset += n
        }
        let response: Data
        switch String(decoding: command, as: UTF8.self) {
        case "STOP\n":
            requestStop()
            response = Data("OK\n".utf8)
        case "STAT\n":
            let state: [String: Any] = readState {
                ["backend": "hvf-libkrun", "phase": phase, "pid": getpid(),
                 "vm_memory_ceiling_mib": ceiling.map { $0 as Any } ?? NSNull(),
                 "guest_total_kib": memory.map { $0.total as Any } ?? NSNull(),
                 "guest_available_kib": memory.map { $0.available as Any } ?? NSNull(),
                 "balloon_target_mib": NSNull(), "host_reclaimed_bytes": NSNull()]
            }
            response = (try? JSONSerialization.data(withJSONObject: state)) ?? Data()
        default: response = Data("ERR\n".utf8)
        }
        try? DockerUnixHTTP.send(fd, response + (command == Array("STAT\n".utf8) ? Data([10]) : Data()))
    }

    private func requestStop() {
        let first = readState {
            guard stopRequestedAt == nil else { return false }
            stopRequestedAt = .now()
            phase = "stopping"
            return true
        }
        guard first else { return }
        shutdownQueue.async {
            trace("Guest stop requested")
            let deadline = DispatchTime.now() + .seconds(30)
            while DispatchTime.now() < deadline {
                if let connection = try? self.connect("shutdown.sock") {
                    // A successful host write can precede Guest vsock readiness.
                    try? DockerUnixHTTP.send(connection.fileDescriptor, Data("SHUTDOWN\n".utf8))
                    withExtendedLifetime(connection) {}
                }
                Thread.sleep(forTimeInterval: 1)
            }
            // If libkrun had observed guest poweroff it would already have exited.
            // Record forced shutdown before releasing the disk lock via process exit.
            trace("Guest shutdown timed out; forcing Helper exit without confirming disk sync")
            try? Data("forced\n".utf8).write(to: self.shutdownDisposition, options: .atomic)
            Darwin._exit(75)
        }
    }

    private func sample() {
        do {
            let response = try DockerUnixHTTP.request("GET", "/containers/json?all=0", timeout: 2, maxBytes: 4_000_000)
            guard response.status == 200, let records = response.json as? [[String: Any]] else { return }
            readState { if phase == "starting" { phase = "ready" } }
            guard !stopping else { return }
            var needed: [UInt16: UInt16] = [:]
            for record in records {
                for binding in record["Ports"] as? [[String: Any]] ?? [] {
                    guard (binding["Type"] as? String) == "tcp",
                          let number = (binding["PublicPort"] as? NSNumber)?.intValue,
                          let port = UInt16(exactly: number), port > 0 else { continue }
                    needed[port] = port // Guest's dockerd maps this published port to the container.
                }
            }
            portListeners?.reconcile(needed)
            let channel = try connect("memory.sock")
            defer { withExtendedLifetime(channel) {} }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 128)
            while bytes.count < 128 && !bytes.contains(10) {
                let size = Darwin.read(channel.fileDescriptor, &buffer, 128 - bytes.count)
                if size < 0 && errno == EINTR { continue }
                guard size > 0 else { break }
                bytes.append(contentsOf: buffer.prefix(size))
            }
            let sample = GuestMemory(String(decoding: bytes, as: UTF8.self))
            if let sample { readState { memory = sample } }
        } catch { /* Guest boot and Docker restart are allowed to be temporarily unready. */ }
    }

    private func approvedShares() throws -> ([String], String) {
        let authorized = try MobyConfig.shares()
        var exports: [String] = [], spec: [String] = []
        for (index, path) in authorized.enumerated() {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            var info = stat()
            guard MobyConfig.allowedShare(resolved), lstat(resolved, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR else { throw hostError("Unsafe or missing share: \(path)") }
            exports.append(resolved)
            spec.append("s\(index)@" + path.utf8.map { String(format: "%02x", $0) }.joined())
        }
        let encoded = spec.joined(separator: ",")
        guard encoded.utf8.count <= 1800 else { throw hostError("Share map exceeds kernel command line limit") }
        return (exports, encoded)
    }

    // The bundled Docker Engine binaries live in the app bundle
    // (Resources/docker/bin). Exported read-only under the "docker" tag when
    // complete; a missing bundle keeps the guest on its seed's engine.
    static func bundledEngineDirectory() -> String? {
        let root = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/docker", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        for name in ["dockerd", "containerd", "runc"] {
            var info = stat()
            guard lstat(bin.appendingPathComponent(name).path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG else { return nil }
        }
        return root.path
    }

    // Same host validation as the probe: Apple-owned, unwritable by group and
    // others, executable interpreter. Opt-out or a missing runtime keeps the
    // helper fully ARM64-capable without failing the VM.
    static func systemRosettaDirectory() -> String? {
        guard ProcessInfo.processInfo.environment["KIRI_MOBY_DISABLE_ROSETTA"] != "1" else { return nil }
        let directory = "/Library/Apple/usr/libexec/oah/RosettaLinux"
        let runtime = "\(directory)/rosetta"
        var root = stat(), file = stat()
        guard lstat(directory, &root) == 0, lstat(runtime, &file) == 0,
              root.st_uid == 0, root.st_mode & S_IFMT == S_IFDIR, root.st_mode & 0o022 == 0,
              file.st_uid == 0, file.st_mode & S_IFMT == S_IFREG, file.st_mode & 0o022 == 0,
              access(runtime, R_OK | X_OK) == 0 else { return nil }
        return directory
    }

    private func run() throws {
        let legacyData = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kiri-moby")
        guard data.resolvingSymlinksInPath().path != legacyData.resolvingSymlinksInPath().path else {
            throw hostError("Local HVF Helper will not open the installed VZ data directory")
        }
        try guardedDirectory(data)
        let lock = Darwin.open(data.appendingPathComponent("moby-vm.lock").path,
                               O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw hostError("Cannot open VM disk lock") }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw hostError("Another Helper owns the VM disk") }
        try guardedDirectory(data.appendingPathComponent("run"))
        try guardedDirectory(data.appendingPathComponent("logs"))
        for name in ["host-control.sock", "docker.sock", "memory.sock", "ports.sock", "shutdown.sock"] {
            try removeStaleSocket(socketPath(name))
        }
        if unlink(shutdownDisposition.path) != 0 && errno != ENOENT {
            throw hostError("Cannot clear previous forced-stop status")
        }
        let control = try unixListen(socketPath("host-control.sock"))
        _ = fcntl(control, F_SETFD, FD_CLOEXEC)
        defer { Darwin.close(control); _ = unlink(socketPath("host-control.sock").path) }
        for signum in [SIGINT, SIGTERM] {
            _ = Darwin.signal(signum, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signum, queue: shutdownQueue)
            source.setEventHandler { [weak self] in self?.requestStop() }
            source.resume()
            signals.append(source)
        }
        controlQueue.async {
            while true {
                let client = Darwin.accept(control, nil, nil)
                if client >= 0 {
                    _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                    self.processControl(client)
                } else if errno != EINTR { break }
            }
        }

        let resources = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true)
        try guardedDirectory(MobyPaths.dockerConfig)
        let config = MobyPaths.dockerConfig.appendingPathComponent("config.json")
        let previous = try? Data(contentsOf: config)
        var cliSettings = previous.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        cliSettings["cliPluginsExtraDirs"] = [resources.appendingPathComponent("bin/cli-plugins").path]
        try JSONSerialization.data(withJSONObject: cliSettings).write(to: config, options: .atomic)
        try MobyVM.installGuestAssets(from: resources, lockHeld: true)
        let (dataDisk, seed) = try prepareDisks(data)
        for disk in [dataDisk, seed] {
            var info = stat()
            guard lstat(disk.path, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                throw hostError("Unsafe VM disk: \(disk.path)")
            }
        }
        let settings = try MobyConfig.readResources()
        let ram = settings["memory_mib"] ?? 4096
        let cpus = settings["cpus"] ?? 4
        let (shares, spec) = try approvedShares()
        if stopping { trace("Stop requested before the VM opened its disks"); return }
        readState { ceiling = ram }
        portListeners = LocalListeners(shouldStop: { [weak self] in self?.stopping ?? true }, connector: { [weak self] _ in
            guard let self else { throw hostError("Helper exited") }
            return try self.connect("ports.sock")
        })
        DispatchQueue.global(qos: .utility).async {
            while !self.stopping {
                self.sample()
                Thread.sleep(forTimeInterval: 2)
            }
            self.portListeners?.stop()
        }
        let strings = shares.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        guard strings.allSatisfy({ $0 != nil }) else { throw hostError("Could not allocate share paths") }
        let exports = strings.map { $0.map { UnsafePointer($0) } }
        let rosetta = HVFHelper.systemRosettaDirectory()
        if let rosetta {
            trace("Apple Linux translation runtime: \(rosetta)")
        } else {
            trace("Apple Linux translation runtime unavailable; amd64 images will not run")
        }
        let engine = HVFHelper.bundledEngineDirectory()
        if let engine {
            trace("Injected Docker Engine: \(engine)")
        } else {
            trace("No bundled Docker Engine; the guest seed's engine will be used")
        }
        trace("Starting in-process libkrun in Helper PID \(getpid())")
        let launch: (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { [self] translation, engineDir in
            data.path.withCString { directory in
                spec.withCString { mapping in
                    exports.withUnsafeBufferPointer { buffer in
                        kiri_hvf_run_helper(directory, UInt32(ram), UInt8(cpus), mapping,
                                            buffer.baseAddress, UInt8(shares.count),
                                            translation, engineDir)
                    }
                }
            }
        }
        let result = rosetta.map { translation in
            launch(translation, engine)
        } ?? launch(nil, engine)
        throw hostError("libkrun returned during launch (\(result)); see logs/console.log")
    }
}
