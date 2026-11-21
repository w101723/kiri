import Darwin
import Foundation

// This entry point is not part of the shipping app. Never point it at the
// installed runtime's data directory or any disk currently used by that VM.
@main
private enum HVFProbe {
    static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(code)
    }

    static func metadata(_ path: String) -> stat {
        var info = stat()
        guard lstat(path, &info) == 0 else { fail("Missing or unreadable probe input: \(path)") }
        return info
    }

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--check-hvf"] {
            let result = kiri_hvf_check()
            guard result == 0 else {
                fail("Hypervisor.framework VM/vCPU creation failed: \(String(UInt32(bitPattern: result), radix: 16))")
            }
            print("Hypervisor.framework VM and vCPU created in Helper PID \(getpid())")
            return
        }
        guard (args.count == 2 || (args.count == 3 && args[2] == "--apple-translation")),
              args[0] == "--run", args[1].hasPrefix("/") else {
            fail("Usage: kiri-hvf-probe --check-hvf | --run /absolute/private/probe-directory [--apple-translation]", code: 2)
        }
        let rosettaDirectory = "/Library/Apple/usr/libexec/oah/RosettaLinux"
        let translation = args.count == 3
        if translation {
            let runtime = "\(rosettaDirectory)/rosetta"
            let root = metadata(rosettaDirectory)
            let file = metadata(runtime)
            guard root.st_uid == 0, root.st_mode & S_IFMT == S_IFDIR, root.st_mode & 0o022 == 0,
                  file.st_uid == 0, file.st_mode & S_IFMT == S_IFREG, file.st_mode & 0o022 == 0,
                  access(runtime, R_OK | X_OK) == 0 else {
                fail("Unsafe or inaccessible system Apple Linux translation runtime: \(runtime)")
            }
        }
        let directory = URL(fileURLWithPath: args[1], isDirectory: true).standardizedFileURL
        let info = metadata(directory.path)
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700 else { fail("Probe directory must be owned by you with mode 0700") }
        let lockPath = directory.appendingPathComponent(".probe-lock").path
        let lock = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { fail("Probe directory is already in use") }
        defer { close(lock) }
        for name in [".kiri-hvf-probe", "Image", "initramfs.cpio", "data.img", "system.img"] {
            let file = metadata(directory.appendingPathComponent(name).path)
            guard file.st_uid == getuid(), file.st_mode & S_IFMT == S_IFREG, file.st_nlink == 1 else {
                fail("Refusing non-regular or linked probe input: \(name)")
            }
        }
        for name in ["console.log", "docker.sock", "shutdown.sock", "memory.sock"] {
            let path = directory.appendingPathComponent(name).path
            var file = stat()
            guard lstat(path, &file) == -1, errno == ENOENT else { fail("Refusing to reuse probe path: \(path)") }
        }
        _ = umask(0o077)
        _ = signal(SIGPIPE, SIG_IGN)
        FileHandle.standardError.write(Data("Starting libkrun in Helper PID \(getpid())\n".utf8))
        let result = directory.path.withCString { path in
            if translation {
                return rosettaDirectory.withCString { kiri_hvf_run(path, 2048, 2, $0) }
            }
            return kiri_hvf_run(path, 2048, 2, nil)
        }
        fail("libkrun returned during VM startup (\(result)); see console.log and Helper logs")
    }
}
