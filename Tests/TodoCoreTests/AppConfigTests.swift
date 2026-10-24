import XCTest
@testable import TodoCore

final class AppConfigTests: XCTestCase {
    func testParsesFullConfig() throws {
        let config = try AppConfig.parse("""
        # TodoTim — https://github.com/timvink/todotim
        repository = "https://github.com/timvink/todotim"

        [sync]
        enabled = true   # trailing comment
        server_url = "https://cloud.example.com/remote.php/dav/files/tim/"
        username = 'tim'
        folder = "Todo # Tim"
        password_command = "rbw get \\"Nextcloud app\\""
        """)
        XCTAssertEqual(config.repository, "https://github.com/timvink/todotim")
        XCTAssertEqual(config.sync, SyncSettings(serverURL: "https://cloud.example.com/remote.php/dav/files/tim/",
                                                 username: "tim", folder: "Todo # Tim", enabled: true))
        XCTAssertEqual(config.passwordCommand, "rbw get \"Nextcloud app\"")
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
        XCTAssertEqual(config.sync?.folder, "TodoTim")
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

    func testPasswordCommand() async throws {
        let password = try await PasswordCommand.run("printf 's3cret\\nignored'")
        XCTAssertEqual(password, "s3cret")
        do {
            _ = try await PasswordCommand.run("echo oops >&2; exit 3")
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("exit 3"))
            XCTAssertTrue(error.localizedDescription.contains("oops"))
        }
        do {
            _ = try await PasswordCommand.run("sleep 5", timeout: 0.2)
            XCTFail("expected timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
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
