import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Runs a program without a shell or run loop (Foundation's `Process` spins the current run loop
/// while waiting, which would let other main-queue work run inside a caller). The child gets its own
/// process group (a timeout kills its descendants too), default signal handling, no inherited file
/// descriptors besides the three standard ones, and `stdin` (or /dev/null). Its stderr is drained
/// and discarded: it may contain secrets.
public enum Subprocess {
    public struct Result: Sendable {
        /// Exit code; nil when the program was killed by a signal (see `signal`) or never reaped.
        public var exitCode: Int32?
        public var signal: Int32?
        public var stdout: Data
        public var timedOut = false
        public var cancelled = false
        public var tooMuchOutput = false
    }

    public struct LaunchError: Error, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    static let killGrace: TimeInterval = 2

    /// Blocks until the program exits (or is killed after `timeout`, cancellation or more than
    /// `maxOutput` bytes on stdout). `argv[0]` is looked up in `PATH`.
    public static func run(_ argv: [String], stdin: Data? = nil, environment: [String: String]? = nil,
                           timeout: TimeInterval, maxOutput: Int = 64 * 1024,
                           isCancelled: () -> Bool = { false }) throws -> Result {
        precondition(!argv.isEmpty)
        var outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1], inPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw LaunchError(message: "\(argv[0]) could not start") }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw LaunchError(message: "\(argv[0]) could not start")
        }
        if stdin != nil, pipe(&inPipe) != 0 {
            close(outPipe[0]); close(outPipe[1]); close(errPipe[0]); close(errPipe[1])
            throw LaunchError(message: "\(argv[0]) could not start")
        }
        // Our pipe ends never reach the program (it gets them as 0, 1 and 2).
        for fd in outPipe + errPipe + inPipe where fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attr = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if stdin != nil {
            posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        #if canImport(Glibc)
        // macOS closes everything else with POSIX_SPAWN_CLOEXEC_DEFAULT below; musl (the static
        // Linux build) has neither, and relies on close-on-exec, which TodoTim's own files all use.
        posix_spawn_file_actions_addclosefrom_np(&actions, 3)
        #endif

        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var flags = Int32(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        #if canImport(Darwin)
        flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        posix_spawnattr_setflags(&attr, Int16(flags))
        posix_spawnattr_setpgroup(&attr, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for sig in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGCHLD, SIGALRM, SIGUSR1, SIGUSR2] {
            sigaddset(&defaultSignals, sig)
        }
        posix_spawnattr_setsigdefault(&attr, &defaultSignals)

        let env = environment ?? ProcessInfo.processInfo.environment
        let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in cArgv + cEnv { free(p) } }
        var pid: pid_t = 0
        let spawnStatus = posix_spawnp(&pid, argv[0], &actions, &attr, cArgv, cEnv)
        close(outPipe[1]); close(errPipe[1])
        if stdin != nil { close(inPipe[0]) }
        guard spawnStatus == 0 else {
            close(outPipe[0]); close(errPipe[0])
            if stdin != nil { close(inPipe[1]) }
            throw LaunchError(message: "\(argv[0]) could not start (\(String(cString: strerror(spawnStatus))))")
        }

        // Small inputs (a password) fit in the pipe buffer; write them before reading.
        if let stdin {
            stdin.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(inPipe[1], raw.baseAddress! + offset, raw.count - offset)
                    if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { break }
                }
            }
            close(inPipe[1])
        }

        var result = Result(exitCode: nil, signal: nil, stdout: Data())
        var openFDs: [Int32] = [outPipe[0], errPipe[0]]
        for fd in openFDs { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        defer { for fd in openFDs { close(fd) } }

        let start = Date()
        var termSentAt: Date?
        var status: Int32?
        var exitedAt: Date?
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        func killGroup(_ sig: Int32) { _ = kill(-pid, sig) }

        while true {
            if status == nil {
                var st: Int32 = 0
                if waitpid(pid, &st, WNOHANG) == pid { status = st; exitedAt = Date() }
            }
            // Done when the output is complete; after the program exited, descendants that keep the
            // pipes open get one second before they are ignored.
            if status != nil && (openFDs.isEmpty || Date().timeIntervalSince(exitedAt!) > 1) { break }

            if termSentAt == nil, status == nil {
                if isCancelled() { result.cancelled = true } else if Date().timeIntervalSince(start) > timeout { result.timedOut = true }
                if result.cancelled || result.timedOut || result.tooMuchOutput {
                    killGroup(SIGTERM)
                    termSentAt = Date()
                }
            } else if let t = termSentAt, status == nil, Date().timeIntervalSince(t) > killGrace {
                killGroup(SIGKILL)
                var st: Int32 = 0
                if waitpid(pid, &st, 0) == pid { status = st; exitedAt = Date() }
                break
            }

            if openFDs.isEmpty {
                usleep(20_000)
                continue
            }
            var fds = openFDs.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            guard poll(&fds, nfds_t(fds.count), 50) > 0 else { continue }
            for p in fds where p.revents != 0 {
                let n = read(p.fd, &buffer, buffer.count)
                if n > 0 {
                    if p.fd == outPipe[0] {
                        if result.stdout.count + n > maxOutput { result.tooMuchOutput = true } else { result.stdout.append(contentsOf: buffer[0..<n]) }
                    }
                } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                    close(p.fd)
                    openFDs.removeAll { $0 == p.fd }
                }
            }
        }
        if let st = status {
            let sig = st & 0x7f
            if sig != 0 { result.signal = sig } else { result.exitCode = (st >> 8) & 0xff }
        }
        return result
    }
}
