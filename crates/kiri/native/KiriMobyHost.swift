// Kiri Moby Host — independent Swift Virtualization.framework daemon.
// macOS arm64 only. Guest agent remains Rust; wire protocol and disk ABI unchanged.
import Foundation
#if !KIRI_HVF_LOCAL
import Virtualization
#endif
import Darwin

#if KIRI_HVF_LOCAL
final class VMConnection {
    let fileDescriptor: Int32
    init(_ fd: Int32) { fileDescriptor = fd }
    deinit { Darwin.close(fileDescriptor) }
}
#else
typealias VMConnection = VZVirtioSocketConnection
#endif

private enum HostError: LocalizedError {
    case problem(String)
    var errorDescription: String? {
        if case .problem(let text) = self { return text }
        return "Kiri Moby Host failed"
    }
}
func hostError(_ message: String) -> LocalizedError { HostError.problem(message) }
func trace(_ message: String) {
    let line = "[Kiri Moby Host] \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}
private let fm = FileManager.default
private let vsockDocker: UInt32 = 2375
private let vsockShutdown: UInt32 = 2376
private let vsockPorts: UInt32 = 2377
private let vsockMemory: UInt32 = 2378

func guardedDirectory(_ url: URL) throws {
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_uid == getuid(),
          info.st_mode & S_IFMT == S_IFDIR else { throw hostError("Unsafe directory: \(url.path)") }
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

private func installDisk(_ archive: URL, _ disk: URL, _ member: String) throws {
    guard fm.fileExists(atPath: archive.path) else { throw hostError("Missing Guest disk seed \(archive.path)") }
    let staging = disk.deletingLastPathComponent().appendingPathComponent("staging-\(member)")
    guard !fm.fileExists(atPath: staging.path) else { throw hostError("Incomplete disk staging: \(staging.path)") }
    try guardedDirectory(staging)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    task.arguments = ["-xzf", archive.path, "-C", staging.path, member]
    task.standardOutput = FileHandle.nullDevice
    try task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0, fm.fileExists(atPath: staging.appendingPathComponent(member).path) else {
        throw hostError("Could not unpack \(member) disk")
    }
    try fm.moveItem(at: staging.appendingPathComponent(member), to: disk)
    try fm.removeItem(at: staging)
}
private func readLineFile(_ path: URL) throws -> String {
    try String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
}
func prepareDisks(_ data: URL) throws -> (URL, URL) {
    let guest = data.appendingPathComponent("guest")
    for name in ["Image", "initramfs.cpio", "data.img.tgz", "system.img.tgz", "rootfs.revision"] {
        guard fm.fileExists(atPath: guest.appendingPathComponent(name).path) else {
            throw hostError("Missing Linux ARM64 Guest asset: \(name)")
        }
    }
    let vm = data.appendingPathComponent("vm")
    try guardedDirectory(vm)
    let disk = vm.appendingPathComponent("data.img")
    if !fm.fileExists(atPath: disk.path) {
        try installDisk(guest.appendingPathComponent("data.img.tgz"), disk, "data.img")
    }
    let revision = try readLineFile(guest.appendingPathComponent("rootfs.revision"))
    guard revision.count == 64, revision.utf8.allSatisfy({
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
    }) else { throw hostError("Unverified Guest rootfs.revision") }
    let seed = vm.appendingPathComponent("system.img")
    let stamp = vm.appendingPathComponent("system.revision")
    if !fm.fileExists(atPath: seed.path) || (try? readLineFile(stamp)) != revision {
        let stage = vm.appendingPathComponent("system-staging")
        guard !fm.fileExists(atPath: stage.path) else {
            throw hostError("Unfinished system seed stage; refusing unsafe overwrite")
        }
        try guardedDirectory(stage)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", guest.appendingPathComponent("system.img.tgz").path,
                         "-C", stage.path, "system.img"]
        tar.standardOutput = FileHandle.nullDevice
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw hostError("System seed extraction failed") }
        let staged = stage.appendingPathComponent("system.img")
        let handle = try FileHandle(forReadingFrom: staged)
        _ = fsync(handle.fileDescriptor)
        try handle.close()
        // Atomic replacement: never delete a working seed before the new one is committed.
        guard Darwin.rename(staged.path, seed.path) == 0 else {
            throw hostError("Atomic system seed replacement failed: \(String(cString: strerror(errno)))")
        }
        try fm.removeItem(at: stage)
        try Data("\(revision)\n".utf8).write(to: stamp, options: .atomic)
    }
    return (disk, seed)
}
#if !KIRI_HVF_LOCAL
private func approvedShares() throws -> ([String: VZSharedDirectory], String) {
    let raw = ProcessInfo.processInfo.environment["KIRI_MOBY_SHARE_DIRS"] ?? ""
    guard !raw.isEmpty else { return ([:], "") }
    let parts = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard !parts.isEmpty, parts.count <= 16, Set(parts).count == parts.count else {
        throw hostError("Share mapping must contain unique 1–16 directories")
    }
    var spec = [String]()
    var dirs: [String: VZSharedDirectory] = [:]
    for (i, path) in parts.enumerated() {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard (path.hasPrefix("/Users/") || path.hasPrefix("/Volumes/")),
              components.count >= 3, !path.contains("/./"), !path.contains("//"),
              !components.contains(".."), !path.contains(","), path == path.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw hostError("Unsafe Mac share path: \(path)")
        }
        var isDir = ObjCBool(false)
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw hostError("Authorized Mac share directory missing: \(path)")
        }
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard canonical.path.hasPrefix("/Users/") || canonical.path.hasPrefix("/Volumes/") else {
            throw hostError("Authorized Mac share resolves outside user/volume directories")
        }
        let name = "s\(i)"
        dirs[name] = VZSharedDirectory(url: canonical, readOnly: false)
        spec.append("\(name)@" + path.utf8.map { String(format: "%02x", $0) }.joined())
    }
    let encoded = spec.joined(separator: ",")
    guard encoded.utf8.count <= 1800 else { throw hostError("Share map exceeds Linux kernel command line limit") }
    return (dirs, encoded)
}
#endif

// poll-based duplex relay: byte-exact HTTP, chunked, binary and upgraded PTY streams.
enum ByteRelay {
    // Single-worker, nonblocking, poll-driven full duplex pump. Each direction
    // has a bounded 64 KiB buffer. Preserve independent half-closes and binary
    // bytes including Docker's 101 Upgrade / exec / attach streams.
    static func relay(_ client: Int32, _ guest: VMConnection) {
        defer { withExtendedLifetime(guest) {} }
        let engine = guest.fileDescriptor
        let clientFlags = fcntl(client, F_GETFL, 0)
        let engineFlags = fcntl(engine, F_GETFL, 0)
        if clientFlags >= 0 { _ = fcntl(client, F_SETFL, clientFlags | O_NONBLOCK) }
        if engineFlags >= 0 { _ = fcntl(engine, F_SETFL, engineFlags | O_NONBLOCK) }
        defer {
            if clientFlags >= 0 { _ = fcntl(client, F_SETFL, clientFlags) }
            if engineFlags >= 0 { _ = fcntl(engine, F_SETFL, engineFlags) }
        }

        var clientEOF = false, engineEOF = false
        var clientWriteClosed = false, engineWriteClosed = false
        var upstream = [UInt8](), downstream = [UInt8]()
        upstream.reserveCapacity(65536)
        downstream.reserveCapacity(65536)

        while true {
            if clientEOF && upstream.isEmpty && !engineWriteClosed {
                _ = shutdown(engine, SHUT_WR)
                engineWriteClosed = true
            }
            if engineEOF && downstream.isEmpty && !clientWriteClosed {
                _ = shutdown(client, SHUT_WR)
                clientWriteClosed = true
            }
            if clientEOF && engineEOF && upstream.isEmpty && downstream.isEmpty { break }
            var fds = [
                pollfd(fd: client, events:
                    ((!clientEOF && upstream.count < 65536) ? Int16(POLLIN) : 0) |
                    (!downstream.isEmpty ? Int16(POLLOUT) : 0), revents: 0),
                pollfd(fd: engine, events:
                    ((!engineEOF && downstream.count < 65536) ? Int16(POLLIN) : 0) |
                    (!upstream.isEmpty ? Int16(POLLOUT) : 0), revents: 0)
            ]
            let status = fds.withUnsafeMutableBufferPointer {
                Darwin.poll($0.baseAddress, nfds_t($0.count), 3000)
            }
            if status < 0 {
                if errno == EINTR { continue }
                break
            }
            if status == 0 { continue }
            if (fds[0].revents & Int16(POLLNVAL | POLLERR)) != 0 ||
               (fds[1].revents & Int16(POLLNVAL | POLLERR)) != 0 { break }

            func receive(_ source: Int32, _ pending: inout [UInt8], _ eof: inout Bool) {
                var scratch = [UInt8](repeating: 0, count: 65536 - pending.count)
                if scratch.isEmpty { return }
                let count = scratch.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, $0.count) }
                if count == 0 { eof = true }
                else if count > 0 { pending.append(contentsOf: scratch.prefix(count)) }
                else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK { eof = true }
            }
            func transmit(_ target: Int32, _ pending: inout [UInt8], _ eof: inout Bool) {
                guard !pending.isEmpty else { return }
                let written = pending.withUnsafeBytes { Darwin.write(target, $0.baseAddress, $0.count) }
                if written > 0 { pending.removeFirst(written) }
                else if written < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                    eof = true
                    pending.removeAll()
                }
            }
            // Try pending bytes before reading more; this caps resident buffers.
            if (fds[1].revents & Int16(POLLOUT)) != 0 { transmit(engine, &upstream, &clientEOF) }
            if (fds[0].revents & Int16(POLLOUT)) != 0 { transmit(client, &downstream, &engineEOF) }
            if (fds[0].revents & Int16(POLLIN | POLLHUP)) != 0 && !clientEOF {
                receive(client, &upstream, &clientEOF)
            }
            if (fds[1].revents & Int16(POLLIN | POLLHUP)) != 0 && !engineEOF {
                receive(engine, &downstream, &engineEOF)
            }
        }
        _ = shutdown(client, SHUT_RDWR)
        _ = shutdown(engine, SHUT_RDWR)
    }
}
func unixListen(_ path: URL) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw hostError("Could not create Unix listener") }
    do {
        let name = Array(path.path.utf8CString)
        guard name.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw hostError("Unix socket path too long")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: name.count) { ptr in
                for i in name.indices { ptr[i] = name[i] }
            }
        }
        let rc = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0, Darwin.listen(fd, 128) == 0 else {
            throw hostError("Cannot listen at \(path.path): \(String(cString: strerror(errno)))")
        }
        chmod(path.path, mode_t(0o600))
        return fd
    } catch { Darwin.close(fd); throw error }
}
private func tcpListen(_ port: UInt16) throws -> Int32 {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw hostError("TCP socket creation failed") }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port.bigEndian)
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let rc = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard rc == 0, Darwin.listen(fd, 128) == 0 else {
        Darwin.close(fd)
        throw hostError("Cannot bind localhost:\(port)")
    }
    return fd
}

struct GuestMemory {
    let total: Int
    let available: Int
    let cached: Int
    init?(_ text: String) {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        guard tokens.count == 4, tokens[0] == "KIRI_MEM_V1",
              let total = Int(tokens[1]), let available = Int(tokens[2]),
              let cached = Int(tokens[3]), total >= 512 * 1024, total <= 256 * 1024 * 1024,
              available >= 0, available <= total, cached >= 0, cached <= total else { return nil }
        self.total = total
        self.available = available
        self.cached = cached
    }
}
private struct MemoryGovernor {
    let ceiling: Int
    private(set) var target: Int
    private var quiet = 0
    init(_ ceiling: Int) { self.ceiling = ceiling; target = ceiling }
    mutating func sample(_ m: GuestMemory) -> Int? {
        let total = m.total / 1024, available = m.available / 1024
        let inflated = max(0, ceiling - target)
        let used = max(0, total - available - inflated)
        let desired = min(ceiling, max(1024, used + 768))
        let next: Int
        if available < 512 && target < ceiling {
            quiet = 0
            next = min(ceiling, max(target + 1024, desired))
        } else if desired > target + 128 {
            quiet = 0
            next = desired
        } else if desired + 128 < target {
            let shrink = min(256, target - desired, max(0, available - 512))
            if shrink < 128 { quiet = 0; return nil }
            quiet += 1
            guard quiet >= 3 else { return nil }
            next = target - shrink
        } else { quiet = 0; return nil }
        guard next != target else { return nil }
        target = next
        return next
    }
}

private final class PortListener {
    let fd: Int32
    let guestPort: UInt16
    private let lock = NSLock()
    private var cancelled = false
    init(fd: Int32, guestPort: UInt16) { self.fd = fd; self.guestPort = guestPort }
    var active: Bool {
        lock.lock(); defer { lock.unlock() }
        return !cancelled
    }
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        if !cancelled {
            cancelled = true
            Darwin.close(fd)
        }
    }
}
final class LocalListeners {
    private let lock = NSLock()
    private var sockets: [UInt16: PortListener] = [:]
    private let shouldStop: () -> Bool
    private let connector: (UInt32) throws -> VMConnection
    init(shouldStop: @escaping () -> Bool, connector: @escaping (UInt32) throws -> VMConnection) {
        self.shouldStop = shouldStop
        self.connector = connector
    }
    func reconcile(_ needed: [UInt16: UInt16]) {
        lock.lock()
        let outdated = sockets.filter { needed[$0.key] != $0.value.guestPort }
        for (port, listener) in outdated {
            listener.stop()
            sockets.removeValue(forKey: port)
        }
        let missing = needed.filter { sockets[$0.key] == nil }
        lock.unlock()
        for (port, guestPort) in missing {
            do {
                let item = PortListener(fd: try tcpListen(port), guestPort: guestPort)
                lock.lock()
                sockets[port] = item
                lock.unlock()
                trace("127.0.0.1:\(port) -> Linux Guest TCP:\(guestPort)")
                DispatchQueue.global(qos: .utility).async {
                    while !self.shouldStop() && item.active {
                        var pfd = pollfd(fd: item.fd, events: Int16(POLLIN), revents: 0)
                        let rc = Darwin.poll(&pfd, 1, 1000)
                        if rc < 0 && errno == EINTR { continue }
                        guard rc >= 0, item.active else { break }
                        if (pfd.revents & Int16(POLLNVAL | POLLERR)) != 0 { break }
                        guard (pfd.revents & Int16(POLLIN)) != 0 else { continue }
                        let client = Darwin.accept(item.fd, nil, nil)
                        if client < 0 { continue }
                        guard item.active else { Darwin.close(client); break }
                        DispatchQueue.global(qos: .utility).async {
                            defer { Darwin.close(client) }
                            do {
                                let guest = try self.connector(vsockPorts)
                                let header = [UInt8(guestPort >> 8), UInt8(guestPort & 0xff)]
                                let written = header.withUnsafeBytes {
                                    Darwin.write(guest.fileDescriptor, $0.baseAddress, 2)
                                }
                                guard written == 2 else { return }
                                ByteRelay.relay(client, guest)
                            } catch { trace("Port forward: \(error)") }
                        }
                    }
                }
            } catch { trace("Skipping conflicting local TCP port \(port): \(error)") }
        }
    }
    func stop() {
        lock.lock()
        for item in sockets.values { item.stop() }
        sockets.removeAll()
        lock.unlock()
    }
}

#if !KIRI_HVF_LOCAL
private final class KiriMobyHost: NSObject, VZVirtualMachineDelegate {
    private let queue = DispatchQueue(label: "dev.kiri.moby.host.virtualization")
    private let stateLock = NSLock()
    private var stopping = false
    private var vmStopped = false
    private var stats = (target: 4096, total: 0, available: 0)
    private var governor: MemoryGovernor
    private var virtualMachine: VZVirtualMachine!
    private var guestSocket: VZVirtioSocketDevice!
    private var consoleHandle: FileHandle?
    private var dockerListener: Int32 = -1
    private var controlListener: Int32 = -1
    private var diskLock: Int32 = -1
    private var tcp: LocalListeners?
    private var signalSources: [DispatchSourceSignal] = []
    private let data: URL
    private let memoryLimit: Int

    init(data: URL, ceiling: Int) {
        self.data = data
        self.memoryLimit = ceiling
        self.governor = MemoryGovernor(ceiling)
    }
    private var shouldStop: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stopping || vmStopped
    }
    private func setStopped() {
        stateLock.lock(); stopping = true; stateLock.unlock()
    }
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        stateLock.lock(); vmStopped = true; stopping = true; stateLock.unlock()
        trace("Guest stopped")
    }
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        trace("Guest stopped with error: \(error)")
        setStopped()
    }
    private func socket(_ port: UInt32) throws -> VZVirtioSocketConnection {
        let signal = DispatchSemaphore(value: 0)
        var answer: Result<VZVirtioSocketConnection, Error>?
        queue.async {
            self.guestSocket.connect(toPort: port) { result in
                answer = result
                signal.signal()
            }
        }
        guard signal.wait(timeout: .now() + 5) == .success, let answer else {
            throw hostError("Guest vsock:\(port) not ready")
        }
        return try answer.get()
    }
    private func setBalloon(_ mib: Int) {
        queue.async {
            if let balloon = self.virtualMachine.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice {
                balloon.targetVirtualMachineMemorySize = UInt64(mib) * 1048576
            }
        }
    }
    private func makeVM(cpu: Int, memory: Int, disk: URL, seed: URL, shares: [String: VZSharedDirectory],
                        spec: String) throws {
        let guest = data.appendingPathComponent("guest")
        let loader = VZLinuxBootLoader(kernelURL: guest.appendingPathComponent("Image"))
        loader.initialRamdiskURL = guest.appendingPathComponent("initramfs.cpio")
        let seconds = Int(Date().timeIntervalSince1970)
        let drops = ProcessInfo.processInfo.environment["KIRI_MOBY_IDLE_DROP_CACHES"] == "1"
        loader.commandLine = "console=hvc0 rdinit=/init panic=-1 kiri.moby_boot_time=\(seconds)" +
            (spec.isEmpty ? "" : " kiri.moby_shares=\(spec)") +
            (drops ? " kiri.moby_idle_drop_caches=1" : "")
        let config = VZVirtualMachineConfiguration()
        config.platform = VZGenericPlatformConfiguration()
        config.bootLoader = loader
        config.cpuCount = cpu
        config.memorySize = UInt64(memory) * 1048576
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        let outputURL = data.appendingPathComponent("logs/console.log")
        if !fm.fileExists(atPath: outputURL.path) { _ = fm.createFile(atPath: outputURL.path, contents: nil) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
        let handle = try FileHandle(forWritingTo: outputURL)
        _ = try handle.seekToEnd()
        consoleHandle = handle
        serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: handle)
        config.serialPorts = [serial]
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        // Persistent disk ABI MUST remain vda=data writable, vdb=seed read-only.
        let dataAttachment = try VZDiskImageStorageDeviceAttachment(
            url: disk, readOnly: false, cachingMode: .cached, synchronizationMode: .fsync)
        let seedAttachment = try VZDiskImageStorageDeviceAttachment(
            url: seed, readOnly: true, cachingMode: .cached, synchronizationMode: .fsync)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: dataAttachment),
                                 VZVirtioBlockDeviceConfiguration(attachment: seedAttachment)]
        var fsDevices = [VZVirtioFileSystemDeviceConfiguration]()
        if !shares.isEmpty {
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: "kiri-mac")
            fs.share = VZMultipleDirectoryShare(directories: shares)
            fsDevices.append(fs)
        }
        if VZLinuxRosettaDirectoryShare.availability == .installed {
            if let rosetta = try? VZLinuxRosettaDirectoryShare() {
                let fs = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
                fs.share = rosetta
                fsDevices.append(fs)
            }
        }
        config.directorySharingDevices = fsDevices
        let ethernet = VZVirtioNetworkDeviceConfiguration()
        ethernet.attachment = VZNATNetworkDeviceAttachment()
        ethernet.macAddress = VZMACAddress(string: "02:4b:69:72:69:01")!
        config.networkDevices = [ethernet]
        try config.validate()
        virtualMachine = VZVirtualMachine(configuration: config, queue: queue)
        virtualMachine.delegate = self
        guestSocket = virtualMachine.socketDevices[0] as? VZVirtioSocketDevice
        guard guestSocket != nil else { throw hostError("VM has no VirtioSocket device") }
    }
    private func startup() throws {
        guard VZVirtualMachine.isSupported else { throw hostError("Virtualization.framework is unsupported") }
        try guardedDirectory(data)
        let lockPath = data.appendingPathComponent("moby-vm.lock").path
        diskLock = Darwin.open(lockPath, O_CREAT | O_RDWR, mode_t(0o600))
        guard diskLock >= 0, flock(diskLock, LOCK_EX | LOCK_NB) == 0 else {
            throw hostError("Another Kiri Moby Host owns the VM data disk")
        }
        let run = data.appendingPathComponent("run")
        try guardedDirectory(run)
        for filename in ["docker.sock", "host-control.sock"] {
            let path = run.appendingPathComponent(filename).path
            var sb = stat()
            if lstat(path, &sb) == 0 {
                guard (sb.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
                    throw hostError("Refusing non-socket or symlink path: \(path)")
                }
                let check = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                if check >= 0 {
                    var addr = sockaddr_un()
                    addr.sun_family = sa_family_t(AF_UNIX)
                    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
                    let chars = Array(path.utf8CString)
                    withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
                        tuple.withMemoryRebound(to: CChar.self, capacity: chars.count) { p in
                            for i in chars.indices { p[i] = chars[i] }
                        }
                    }
                    let rc = withUnsafePointer(to: &addr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            Darwin.connect(check, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                        }
                    }
                    Darwin.close(check)
                    guard rc != 0 else { throw hostError("Active Moby listener already owns \(path)") }
                }
                guard unlink(path) == 0 else { throw hostError("Cannot unlink stale socket \(path)") }
            }
        }
        try guardedDirectory(data.appendingPathComponent("logs"))
        let (disk, seed) = try prepareDisks(data)
        let (shares, spec) = try approvedShares()
        let env = ProcessInfo.processInfo.environment
        let cpus = Int(env["KIRI_MOBY_CPUS"] ?? "") ?? 4
        let cpusLimit = min(16, ProcessInfo.processInfo.activeProcessorCount)
        guard (1...cpusLimit).contains(cpus), (1024...65536).contains(memoryLimit) else {
            throw hostError("Invalid VM CPU or RAM limit")
        }
        try makeVM(cpu: cpus, memory: memoryLimit, disk: disk, seed: seed, shares: shares, spec: spec)
        let started = DispatchSemaphore(value: 0)
        var startError: Error?
        queue.async {
            self.virtualMachine.start { result in
                if case .failure(let error) = result { startError = error }
                started.signal()
            }
        }
        guard started.wait(timeout: .now() + 40) == .success else { throw hostError("VZ VM start timed out") }
        if let startError { throw startError }
        dockerListener = try unixListen(run.appendingPathComponent("docker.sock"))
        controlListener = try unixListen(run.appendingPathComponent("host-control.sock"))
        trace("VM started: unix://\(run.appendingPathComponent("docker.sock").path)")
        trace("Default Docker context unchanged")
    }
    private func acceptLoop(_ fd: Int32, _ handler: @escaping (Int32) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            while !self.shouldStop {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let polled = Darwin.poll(&pfd, 1, 1000)
                if polled <= 0 { continue }
                guard (pfd.revents & Int16(POLLIN)) != 0 else { continue }
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else { continue }
                DispatchQueue.global(qos: .utility).async { handler(client) }
            }
        }
    }
    private func handleDocker(_ fd: Int32) {
        defer { Darwin.close(fd) }
        do {
            let guest = try socket(vsockDocker)
            ByteRelay.relay(fd, guest)
        } catch { trace("Docker vsock connect: \(error)") }
    }
    private func handleControl(_ fd: Int32) {
        defer { Darwin.close(fd) }
        var buffer = [UInt8](repeating: 0, count: 5)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count == 5 else { return }
        let command = String(decoding: buffer, as: UTF8.self)
        if command == "STOP\n" {
            _ = Array("OK\n".utf8).withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            setStopped()
        } else if command == "STAT\n" {
            stateLock.lock()
            let report = stats
            stateLock.unlock()
            let response: [String: Any] = [
                "balloon_target_mib": report.target, "vm_memory_ceiling_mib": memoryLimit,
                "guest_total_kib": report.total, "guest_available_kib": report.available,
                "host_reclaimed_bytes": NSNull()]
            if let data = try? JSONSerialization.data(withJSONObject: response) {
                let bytes = data + Data("\n".utf8)
                bytes.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
            }
        } else {
            _ = Array("ERR\n".utf8).withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        }
    }
    private func readGuestMemory() {
        do {
            let connection = try socket(vsockMemory)
            let fd = connection.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 128)
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&pfd, 1, 2000) > 0 else { return }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count > 0, let sample = GuestMemory(String(decoding: buffer.prefix(count), as: UTF8.self)) else { return }
            stateLock.lock()
            let next = governor.sample(sample)
            stats = (target: governor.target, total: sample.total, available: sample.available)
            stateLock.unlock()
            if ProcessInfo.processInfo.environment["KIRI_MOBY_MEMORY_POLICY"] != "off",
               let next {
                setBalloon(next)
                trace("Memory balloon target -> \(next) MiB; Guest available \(sample.available / 1024) MiB")
            }
        } catch { /* Guest may be starting; fail open, never shrink without telemetry. */ }
    }
    // Read standard Docker /containers JSON over the private UDS, no curl process.
    private func dockerContainers() -> [[String: Any]]? {
        let path = data.appendingPathComponent("run/docker.sock")
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let chars = Array(path.path.utf8CString)
        guard chars.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: chars.count) {
                for i in chars.indices { $0[i] = chars[i] }
            }
        }
        let rc = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { return nil }
        let request = Array("GET /containers/json?all=0 HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n".utf8)
        let written = request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == request.count else { return nil }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while data.count < 4_000_000 {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&pfd, 1, 1500) > 0 else { break }
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            data.append(contentsOf: buffer.prefix(n))
        }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<boundary.lowerBound], as: UTF8.self)
        guard head.hasPrefix("HTTP/1.1 200") || head.hasPrefix("HTTP/1.0 200") else { return nil }
        let payload = Data(data[boundary.upperBound...])
        var decoded = payload
        // The Go Docker API is allowed to stream a bounded JSON response with
        // Transfer-Encoding: chunked even when it is not an /events endpoint.
        // A failed parse preserves the last port map rather than dropping ports.
        if head.lowercased().contains("transfer-encoding: chunked") {
            let bytes = [UInt8](payload)
            var offset = 0
            var body = Data()
            var complete = false
            while offset < bytes.count {
                guard let newline = bytes[offset...].firstIndex(of: 10) else { return nil }
                let line = String(decoding: bytes[offset..<newline], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let first = line.split(separator: ";", maxSplits: 1).first,
                      let size = Int(first, radix: 16), size >= 0 else { return nil }
                offset = newline + 1
                if size == 0 { complete = true; break }
                guard offset + 2 <= bytes.count,
                      size <= bytes.count - offset - 2,
                      body.count + size <= 4_000_000 else { return nil }
                body.append(contentsOf: bytes[offset..<(offset + size)])
                offset += size
                guard bytes[offset] == 13, bytes[offset + 1] == 10 else { return nil }
                offset += 2
            }
            guard complete else { return nil }
            decoded = body
        } else if let contentLine = head.components(separatedBy: "\r\n").first(where: {
            $0.lowercased().hasPrefix("content-length:")
        }) {
            guard let length = Int(contentLine.split(separator: ":", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
                  length >= 0, length <= payload.count else { return nil }
            decoded = Data(payload.prefix(length))
        }
        return (try? JSONSerialization.jsonObject(with: decoded)) as? [[String: Any]]
    }
    private func startPortsWatcher() {
        let disable = ProcessInfo.processInfo.environment["KIRI_MOBY_DISABLE_PORT_FORWARD"] == "1"
        if disable { return }
        tcp = LocalListeners(shouldStop: { [weak self] in self?.shouldStop ?? true },
                             connector: { [weak self] port in
                                guard let self else { throw hostError("VM stopped") }
                                return try self.socket(port)
                             })
        DispatchQueue.global(qos: .background).async {
            while !self.shouldStop {
                if let containers = self.dockerContainers() {
                    var desired: [UInt16: UInt16] = [:]
                    for item in containers {
                        for port in item["Ports"] as? [[String: Any]] ?? [] {
                            guard (port["Type"] as? String) == "tcp",
                                  let publicPort = (port["PublicPort"] as? NSNumber)?.uint16Value,
                                  let privatePort = (port["PublicPort"] as? NSNumber)?.uint16Value,
                                  publicPort > 0, privatePort > 0 else { continue }
                            // Docker publishes the guest port; the guest handles NAT to container.
                            desired[publicPort] = privatePort
                        }
                    }
                    self.tcp?.reconcile(desired)
                }
                for _ in 0..<5 where !self.shouldStop { Thread.sleep(forTimeInterval: 1) }
            }
        }
    }
    private func shutdownVM() {
        tcp?.stop()
        if let guest = try? socket(vsockShutdown) {
            let bytes = Array("SHUTDOWN\n".utf8)
            bytes.withUnsafeBytes { _ = Darwin.write(guest.fileDescriptor, $0.baseAddress, $0.count) }
        }
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            stateLock.lock()
            let stopped = vmStopped
            stateLock.unlock()
            if stopped { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        stateLock.lock()
        let stopped = vmStopped
        stateLock.unlock()
        if !stopped {
            let done = DispatchSemaphore(value: 0)
            queue.async {
                self.virtualMachine.stop { _ in done.signal() }
            }
            _ = done.wait(timeout: .now() + 12)
        }
        if dockerListener >= 0 { Darwin.close(dockerListener) }
        if controlListener >= 0 { Darwin.close(controlListener) }
        for name in ["docker.sock", "host-control.sock"] {
            _ = unlink(data.appendingPathComponent("run/\(name)").path)
        }
        if diskLock >= 0 { flock(diskLock, LOCK_UN); Darwin.close(diskLock) }
        trace("Kiri Moby Host exited; VM disk released")
    }
    func run() throws {
        try startup()
        // A Helper survives UI termination but must stop the Guest cleanly on SIGTERM.
        for signum in [SIGINT, SIGTERM] {
            _ = Darwin.signal(signum, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signum, queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in self?.setStopped() }
            source.resume()
            signalSources.append(source)
        }
        acceptLoop(dockerListener) { [weak self] client in self?.handleDocker(client) }
        acceptLoop(controlListener) { [weak self] client in self?.handleControl(client) }
        startPortsWatcher()
        while !shouldStop {
            readGuestMemory()
            for _ in 0..<20 where !shouldStop { Thread.sleep(forTimeInterval: 0.1) }
        }
        shutdownVM()
    }
}

@main
private enum HostMain {
    static func main() {
        guard #available(macOS 14, *) else {
            trace("macOS 14 or newer required")
            exit(1)
        }
        if CommandLine.arguments.contains("--version") {
            print("kiri-moby-host swift-native")
            return
        }
        // Ignore writes to disconnected Docker peers; one EPIPE must not kill the VM.
        _ = Darwin.signal(SIGPIPE, SIG_IGN)
        let env = ProcessInfo.processInfo.environment
        let data = URL(fileURLWithPath: env["KIRI_MOBY_DATA_DIR"] ??
            fm.homeDirectoryForCurrentUser.appendingPathComponent(".kiri-moby").path)
        let ceiling = Int(env["KIRI_MOBY_MEMORY_MIB"] ?? "") ?? 4096
        do {
            let host = KiriMobyHost(data: data, ceiling: ceiling)
            try host.run()
        } catch {
            trace("FATAL: \(error)")
            exit(1)
        }
    }
}
#endif
