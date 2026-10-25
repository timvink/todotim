import XCTest
@testable import TodoCore

final class AppConfigTests: XCTestCase {
    func testParsesFullConfig() throws {
        let config = try AppConfig.parse("""
        # TodoTim — https://github.com/timvink/todotim
        repository = "https://github.com/timvink/todotim"

        [sync]
        enabled = true   # trailing comment
        server_url = "https://cloud.example.com/remote.php/dav/"
        username = 'tim'
        password_command = "rbw get \\"Nextcloud app\\""
        share_with = ["tasks-agent", 'other # not a comment', ]
        """)
        XCTAssertEqual(config.repository, "https://github.com/timvink/todotim")
        XCTAssertEqual(config.sync, SyncSettings(serverURL: "https://cloud.example.com/remote.php/dav/",
                                                 username: "tim", enabled: true))
        XCTAssertEqual(config.passwordCommand, "rbw get \"Nextcloud app\"")
        XCTAssertEqual(config.shareWith, ["tasks-agent", "other # not a comment"])
        XCTAssertEqual(config.ignoredKeys, [])
    }

    func testOldFolderKeyIsIgnoredAndShareWithIsValidated() throws {
        let config = try AppConfig.parse("[sync]\nusername = \"tim\"\nfolder = \"TodoTim\"\n")
        XCTAssertEqual(config.ignoredKeys, ["sync.folder"])
        XCTAssertThrowsError(try AppConfig.parse("[sync]\nshare_with = \"tasks-agent\"\n"))
        XCTAssertThrowsError(try AppConfig.parse("[sync]\nshare_with = [1]\n"))
        XCTAssertThrowsError(try AppConfig.parse("[sync]\nshare_with = [\"a</x>\"]\n"))
        XCTAssertEqual(try AppConfig.parse("[sync]\nshare_with = []\n").shareWith, [])
    }

    func testDefaultsWithoutSyncTable() throws {
        let config = try AppConfig.parse("repository = \"https://example.com/fork\"\n")
        XCTAssertNil(config.sync)
        XCTAssertEqual(config.repository, "https://example.com/fork")
        XCTAssertEqual(try AppConfig.parse("").repository, AppConfig.defaultRepository)
    }

    func testSyncDefaults() throws {
        let config = try AppConfig.parse("[sync]\nusername = \"tim\"\n")
        XCTAssertEqual(config.sync?.enabled, true)
        XCTAssertEqual(config.shareWith, [])
    }

    func testRejectsUnknownKeysAndBadTypes() {
        XCTAssertThrowsError(try AppConfig.parse("[sync]\nuser = \"tim\"\n"))
        XCTAssertThrowsError(try AppConfig.parse("[sync]\nenabled = \"yes\"\n"))
        XCTAssertThrowsError(try AppConfig.parse("[sync]\nusername = tim\n"))
        XCTAssertThrowsError(try AppConfig.parse("[sync\n"))
        XCTAssertThrowsError(try AppConfig.parse("a = 1\na = 2\n"))
    }

    func testLoadMissingFileReturnsNil() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID()).toml")
        XCTAssertNil(try AppConfig.load(from: url))
    }

    func testLoadInvalidFileNamesPath() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID()).toml")
        try "[sync]\nnope = 1\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try AppConfig.load(from: url)) { error in
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains(url.path) == true)
        }
    }

    #if os(macOS)  // password_command needs posix_spawn's macOS flags and a login shell
    func testPasswordCommand() async throws {
        let password = try await PasswordCommand.run("printf 's3cret\\nignored'")
        XCTAssertEqual(password, "s3cret")
        do {
            _ = try await PasswordCommand.run("echo secret-token >&2; exit 3")
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("exit 3"))
            XCTAssertFalse(error.localizedDescription.contains("secret-token"), "stderr is never shown")
        }
        do {
            _ = try await PasswordCommand.run("true")
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("printed nothing"))
        }
        do {
            _ = try await PasswordCommand.run("sleep 5", timeout: 0.2)
            XCTFail("expected timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
    }
    #endif
}

#if os(macOS)  // password_command needs posix_spawn's macOS flags and a login shell
final class PasswordCommandLimitTests: XCTestCase {
    private func elapsed(_ body: () async throws -> Void) async -> (TimeInterval, Error?) {
        let start = Date()
        do { try await body(); return (Date().timeIntervalSince(start), nil) } catch { return (Date().timeIntervalSince(start), error) }
    }

    func testTimeoutEscalatesToSIGKILL() async {
        let (t, error) = await elapsed { _ = try await PasswordCommand.run("trap '' TERM; sleep 30", timeout: 0.2) }
        XCTAssertTrue(error?.localizedDescription.contains("timed out") == true, "\(String(describing: error))")
        XCTAssertLessThan(t, 6)
    }

    func testTimeoutKillsDescendantsHoldingThePipes() async throws {
        let marker = "todotim-test-\(UUID().uuidString.prefix(8))"
        let (t, error) = await elapsed {
            _ = try await PasswordCommand.run("sh -c 'sleep 30; echo \(marker)' & sleep 30", timeout: 0.2)
        }
        XCTAssertTrue(error?.localizedDescription.contains("timed out") == true)
        XCTAssertLessThan(t, 6)
        try await Task.sleep(for: .milliseconds(200))
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", marker]
        pgrep.standardOutput = FileHandle.nullDevice
        try pgrep.run()
        pgrep.waitUntilExit()
        XCTAssertEqual(pgrep.terminationStatus, 1, "no process of the group survives")
    }

    func testBackgroundChildDoesNotBlockResult() async throws {
        let (t, error) = await elapsed {
            let pw = try await PasswordCommand.run("sleep 3 & echo pw", timeout: 10)
            XCTAssertEqual(pw, "pw")
        }
        XCTAssertNil(error)
        XCTAssertLessThan(t, 2.5)
    }

    func testOutputIsCapped() async {
        let (_, error) = await elapsed { _ = try await PasswordCommand.run("head -c 200000 /dev/zero | tr '\\0' a") }
        XCTAssertTrue(error?.localizedDescription.contains("KB") == true, "\(String(describing: error))")
        // Lots of stderr does not block and is not shown.
        let pw = try? await PasswordCommand.run("head -c 1000000 /dev/zero >&2; echo ok")
        XCTAssertEqual(pw, "ok")
    }

    func testCancellationStopsTheCommand() async {
        let task = Task { try await PasswordCommand.run("sleep 30", timeout: 60) }
        try? await Task.sleep(for: .milliseconds(200))
        let start = Date()
        task.cancel()
        let result = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        guard case .failure(let error) = result, error is CancellationError else { return XCTFail("\(result)") }
    }
}
#endif

final class ConfigTrustTests: XCTestCase {
    private var dir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("todotim-config-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? fm.removeItem(at: dir)
    }

    private func write(_ name: String, mode: Int, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? dir).appendingPathComponent(name)
        try "[sync]\nusername = \"tim\"\n".write(to: url, atomically: false, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    private func assertUntrusted(_ url: URL, _ fragment: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try AppConfig.load(from: url), file: file, line: line) { error in
            guard case .untrusted? = error as? AppConfig.LoadError else { return XCTFail("\(error)", file: file, line: line) }
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains(fragment), message, file: file, line: line)
        }
    }

    func testPrivateAndReadOnlyFilesLoad() throws {
        XCTAssertEqual(try AppConfig.load(from: write("a.toml", mode: 0o600))?.sync?.username, "tim")
        XCTAssertNotNil(try AppConfig.load(from: write("b.toml", mode: 0o644)))
        XCTAssertNotNil(try AppConfig.load(from: write("c.toml", mode: 0o400)))
    }

    func testGroupOrWorldWritableFileIsRefused() throws {
        assertUntrusted(try write("g.toml", mode: 0o620), "chmod 600")
        assertUntrusted(try write("w.toml", mode: 0o602), "writable by other users")
    }

    func testSymlinksAreResolved() throws {
        let target = try write("target.toml", mode: 0o600)
        let link = dir.appendingPathComponent("link.toml")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertNotNil(try AppConfig.load(from: link))

        let bad = try write("bad-target.toml", mode: 0o666)
        let badLink = dir.appendingPathComponent("bad-link.toml")
        try fm.createSymbolicLink(at: badLink, withDestinationURL: bad)
        assertUntrusted(badLink, "bad-target.toml")

        let dangling = dir.appendingPathComponent("dangling.toml")
        try fm.createSymbolicLink(at: dangling, withDestinationURL: dir.appendingPathComponent("nope.toml"))
        XCTAssertNil(try AppConfig.load(from: dangling))
    }

    func testWritableFolderIsRefusedUnlessSticky() throws {
        let shared = dir.appendingPathComponent("shared")
        try fm.createDirectory(at: shared, withIntermediateDirectories: false)
        let url = try write("x.toml", mode: 0o600, in: shared)
        try fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: shared.path)
        assertUntrusted(url, "chmod go-w")
        try fm.setAttributes([.posixPermissions: 0o1777], ofItemAtPath: shared.path)
        XCTAssertNotNil(try AppConfig.load(from: url))
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shared.path)
    }

    func testNonRegularFileIsRefused() throws {
        let sub = dir.appendingPathComponent("folder.toml")
        try fm.createDirectory(at: sub, withIntermediateDirectories: false)
        XCTAssertThrowsError(try AppConfig.load(from: sub))
    }
}

final class UserConfigFileTests: XCTestCase {
    /// `TODOTIM_CONFIG=~/.todotim.toml swift test --filter UserConfigFileTests` checks a real config file.
    func testConfigFromEnvironmentLoads() throws {
        guard ProcessInfo.processInfo.environment["TODOTIM_CONFIG"] != nil else { throw XCTSkip("TODOTIM_CONFIG not set") }
        let config = try XCTUnwrap(try AppConfig.load())
        XCTAssertNotNil(config.sync)
    }
}
