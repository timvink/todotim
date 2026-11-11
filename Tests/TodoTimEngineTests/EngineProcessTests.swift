import Foundation
import XCTest
@testable import TodoTimEngine
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The `todotim-engine` process itself: how it reads stdin and how it quits.
/// Test methods are `async` because Linux XCTest cannot run synchronous @MainActor test methods.
final class EngineProcessTests: XCTestCase {
    func testReadLinesSplitsChunksAndStripsLineEnds() async throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        let writer = Thread {
            for chunk in ["{\"a\":1}\n{\"b\"", ":2}\r\n\n", "last"] {
                _ = chunk.utf8CString.withUnsafeBufferPointer { write(fds[1], $0.baseAddress, $0.count - 1) }
                usleep(10_000)
            }
            close(fds[1])
        }
        writer.start()
        var lines: [String] = []
        EngineMain.readLines(from: fds[0]) { lines.append($0) }
        close(fds[0])
        XCTAssertEqual(lines, ["{\"a\":1}", "{\"b\":2}", "", "last"])
    }

    /// SIGTERM, SIGINT and SIGHUP save and exit while the reader waits on stdin. The engine used
    /// to hang in `exit` (stdio's stdin lock was held by `readLine`), alive with the data folder
    /// locked, and the shell plugin's `running = false` could not stop it.
    func testQuitSignalsSaveAndExitWhileStdinIsOpen() async throws {
        let engine = try Self.engineExecutable()
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("engine-proc-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let process = Process()
            process.executableURL = engine
            process.arguments = ["--data-dir", dir.path, "--no-sync"]
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            try process.run()

            stdin.fileHandleForWriting.write(Data("{\"req\":1,\"cmd\":\"quickAdd\",\"text\":\"saved on quit\"}\n".utf8))
            let reply = try Self.readUntil("\"re\":1", from: stdout.fileHandleForReading, timeout: 10)
            XCTAssertTrue(reply.contains("\"ok\":true"), reply)

            // Usually within the 0.3 s save delay, so the quit handler's flush saves it.
            kill(process.processIdentifier, sig)
            if exited.wait(timeout: .now() + 5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                XCTFail("signal \(sig): the engine did not exit")
                continue
            }
            XCTAssertEqual(process.terminationReason, .exit, "signal \(sig)")
            XCTAssertEqual(process.terminationStatus, 0, "signal \(sig)")
            let db = try String(contentsOf: dir.appendingPathComponent("db.json"), encoding: .utf8)
            XCTAssertTrue(db.contains("saved on quit"), "signal \(sig): the task was not saved")
            try? stdin.fileHandleForWriting.close()
        }
    }

    /// The `todotim-engine` that SwiftPM built next to the test bundle.
    static func engineExecutable() throws -> URL {
        var dirs = [Bundle(for: EngineProcessTests.self).bundleURL.deletingLastPathComponent()]
        dirs.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent())
        for dir in dirs {
            let url = dir.appendingPathComponent("todotim-engine")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw XCTSkip("todotim-engine was not built next to the tests (\(dirs.map(\.path)))")
    }

    /// Reads `handle` until `marker` appears; fails after `timeout` seconds.
    static func readUntil(_ marker: String, from handle: FileHandle, timeout: TimeInterval) throws -> String {
        final class Box: @unchecked Sendable { var text = "" }
        let box = Box(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while !box.text.contains(marker) {
                let data = handle.availableData
                if data.isEmpty { break }
                box.text += String(decoding: data, as: UTF8.self)
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            throw NSError(domain: "EngineProcessTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "no \(marker) from the engine"])
        }
        return box.text
    }
}
