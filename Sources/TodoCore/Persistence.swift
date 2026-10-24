import Foundation

/// Local database file: ~/Library/Application Support/TodoTim/db.json
public enum LocalPersistence {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TodoTim", isDirectory: true)
    }

    public static var fileURL: URL { directory.appendingPathComponent("db.json") }

    /// Loads the database. A missing file is an empty database. A file that cannot be decoded is
    /// moved aside to `db.corrupt-<timestamp>.json` (so a later save cannot overwrite it) and
    /// `PersistenceError.corrupt` is thrown. A file that exists but cannot be read throws
    /// `PersistenceError.unreadable` and is left in place.
    public static func loadChecked(from url: URL = fileURL, now: Date = Date()) throws -> Database {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return Database()
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) { return Database() }
            throw PersistenceError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        do {
            return try JSONCoding.decoder.decode(Database.self, from: data)
        } catch {
            let backup = corruptBackupURL(for: url, now: now)
            do {
                try FileManager.default.moveItem(at: url, to: backup)
                chmod(backup.path, 0o600)
            } catch {
                throw PersistenceError.unreadable(path: url.path, reason: "corrupt and could not be moved aside: \(error.localizedDescription)")
            }
            throw PersistenceError.corrupt(backupPath: backup.path, reason: String(describing: error))
        }
    }

    /// Off-main-actor variant of `loadChecked` for launch.
    public static func loadInBackground(from url: URL = fileURL) async throws -> Database {
        try await Task.detached(priority: .userInitiated) { try loadChecked(from: url) }.value
    }

    /// Convenience that never throws: on a corrupt file the original is preserved as
    /// `db.corrupt-<timestamp>.json` (see `loadChecked`) and an empty database is returned.
    /// Prefer `loadChecked` so the user can be told about the recovery.
    public static func load(from url: URL = fileURL) -> Database {
        do {
            return try loadChecked(from: url)
        } catch {
            NSLog("TodoTim: could not load database: \(error.localizedDescription)")
            return Database()
        }
    }

    /// Writes compact JSON atomically. Synchronous; prefer `PersistenceWriter` on the main actor.
    /// The file (and its temporary file) is private to the user (0600). A folder created here, and
    /// the default `directory`, are 0700.
    public static func save(_ db: Database, to url: URL = fileURL) throws {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } else if dir.standardizedFileURL == directory.standardizedFileURL {
            chmod(dir.path, 0o700)
        }
        try writePrivately(JSONCoding.compactEncoder.encode(db), to: url)
    }

    /// Atomic write: a 0600 temporary file in the same folder, renamed over `url`.
    static func writePrivately(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path, NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)]) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(tmp.path, url.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path, NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
            }
        } catch {
            unlink(tmp.path)
            throw error
        }
        chmod(url.path, 0o600)
    }

    /// `db.corrupt-20261024-175700.json` next to `url` (with a numeric suffix if taken).
    static func corruptBackupURL(for url: URL, now: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stem = url.deletingPathExtension().lastPathComponent + ".corrupt-" + f.string(from: now)
        let dir = url.deletingLastPathComponent()
        var candidate = dir.appendingPathComponent(stem + ".json")
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(stem)-\(n).json")
            n += 1
        }
        return candidate
    }
}

public enum PersistenceError: LocalizedError, Equatable, Sendable {
    /// The database file could not be decoded; it was moved to `backupPath`.
    case corrupt(backupPath: String, reason: String)
    /// The database file exists but could not be read (left in place).
    case unreadable(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let backup, _):
            return "The local database was damaged and could not be read. It was saved as “\((backup as NSString).lastPathComponent)” and TodoTim started with an empty database. If sync is enabled, your tasks will be restored from the server."
        case .unreadable(let path, let reason):
            return "Could not read the local database at “\(path)”: \(reason)"
        }
    }
}

/// Saves database snapshots off the main actor.
///
/// `save` only stores the snapshot (O(1): `Database` is copy-on-write) and schedules a write after
/// `delay` on a serial queue; snapshots arriving before the write starts replace the pending one,
/// so only the newest is encoded and older writes can never land after newer ones. `flush()`
/// writes any pending snapshot synchronously (call it on app termination).
public final class PersistenceWriter: @unchecked Sendable {
    public let url: URL
    private let delay: TimeInterval
    private let queue = DispatchQueue(label: "TodoTim.PersistenceWriter", qos: .utility)
    private let lock = NSLock()
    private var pending: Database?
    private var scheduled = false
    private var _writeCount = 0
    private let onError: (@Sendable (Error) -> Void)?

    /// - Parameters:
    ///   - delay: coalescing window in seconds before a scheduled write starts.
    ///   - onError: called on the writer's queue when a write fails.
    public init(url: URL = LocalPersistence.fileURL, delay: TimeInterval = 0.3,
                onError: (@Sendable (Error) -> Void)? = nil) {
        self.url = url
        self.delay = delay
        self.onError = onError
    }

    /// Number of snapshots written so far (for tests and diagnostics).
    public var writeCount: Int { lock.withLock { _writeCount } }

    /// Queues `db` to be written. Cheap; safe to call on every change.
    public func save(_ db: Database) {
        let schedule: Bool = lock.withLock {
            pending = db
            if scheduled { return false }
            scheduled = true
            return true
        }
        if schedule {
            queue.asyncAfter(deadline: .now() + delay) { [self] in drain() }
        }
    }

    /// Blocks until every snapshot passed to `save` so far is on disk.
    public func flush() {
        queue.sync { drain() }
    }

    private func drain() {
        let db: Database? = lock.withLock {
            let p = pending
            pending = nil
            scheduled = false
            return p
        }
        guard let db else { return }
        do {
            try LocalPersistence.save(db, to: url)
            lock.withLock { _writeCount += 1 }
        } catch {
            if let onError { onError(error) } else { NSLog("TodoTim: failed to save database: \(error)") }
        }
    }
}

public enum JSONCoding {
    /// Canonical encoder for remote files: sorted keys and pretty printed, so identical content
    /// produces identical bytes on every device.
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601WithFractionalSeconds
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    /// Compact encoder for the local database file.
    public static var compactEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601WithFractionalSeconds
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601WithFractionalSeconds
        return d
    }
}

/// Fast UTC formatting/parsing of `yyyy-MM-ddTHH:mm:ss.SSS` (the format of every stored date).
/// Format styles are slow enough to dominate encoding 10,000+ dates per save.
enum MillisecondDate {
    static func format(_ date: Date) -> String {
        let totalMs = Int64((date.timeIntervalSince1970 * 1000).rounded())
        var secs = totalMs / 1000
        var ms = totalMs % 1000
        if ms < 0 { ms += 1000; secs -= 1 }
        var days = secs / 86400
        var rem = secs % 86400
        if rem < 0 { rem += 86400; days -= 1 }
        let (y, m, d) = civil(fromDays: days)
        var bytes = [UInt8](repeating: 0, count: 23)
        func put(_ v: Int64, _ at: Int, _ width: Int) {
            var v = v
            for k in stride(from: at + width - 1, through: at, by: -1) {
                bytes[k] = UInt8(48 + v % 10)
                v /= 10
            }
        }
        put(y, 0, 4); bytes[4] = 45  // -
        put(m, 5, 2); bytes[7] = 45
        put(d, 8, 2); bytes[10] = 84  // T
        put(rem / 3600, 11, 2); bytes[13] = 58  // :
        put(rem / 60 % 60, 14, 2); bytes[16] = 58
        put(rem % 60, 17, 2); bytes[19] = 46  // .
        put(ms, 20, 3)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Parses `yyyy-MM-ddTHH:mm:ss` with an optional `.S…` fraction (up to 3 digits) and no zone
    /// (UTC). Returns nil for anything else so callers can fall back to a general parser.
    static func parse(_ s: String) -> Date? {
        var s = s
        return s.withUTF8 { b -> Date? in
            guard b.count == 19 || (b.count >= 21 && b.count <= 23 && b[19] == 46) else { return nil }
            func num(_ at: Int, _ width: Int) -> Int64? {
                var v: Int64 = 0
                for k in at..<(at + width) {
                    let c = b[k]
                    guard c >= 48, c <= 57 else { return nil }
                    v = v * 10 + Int64(c - 48)
                }
                return v
            }
            guard b[4] == 45, b[7] == 45, b[10] == 84, b[13] == 58, b[16] == 58,
                  let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
                  let h = num(11, 2), let mi = num(14, 2), let sec = num(17, 2),
                  (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, sec < 60 else { return nil }
            var ms: Int64 = 0
            if b.count > 19 {
                let digits = b.count - 20
                guard let f = num(20, digits) else { return nil }
                ms = f * (digits == 1 ? 100 : digits == 2 ? 10 : 1)
            }
            let days = daysFromCivil(y, mo, d)
            let totalMs = ((days * 86400) + h * 3600 + mi * 60 + sec) * 1000 + ms
            return Date(timeIntervalSince1970: Double(totalMs) / 1000)
        }
    }

    // Howard Hinnant's civil-date algorithms (proleptic Gregorian, UTC).
    static func daysFromCivil(_ y: Int64, _ m: Int64, _ d: Int64) -> Int64 {
        let y = m <= 2 ? y - 1 : y
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    static func civil(fromDays z: Int64) -> (Int64, Int64, Int64) {
        let z = z + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
}

extension JSONEncoder.DateEncodingStrategy {
    static var iso8601WithFractionalSeconds: Self {
        .custom { date, encoder in
            // Milliseconds are rounded (not truncated) so decode → encode never drifts by 1 ms.
            var c = encoder.singleValueContainer()
            try c.encode(MillisecondDate.format(date))
        }
    }
}

extension JSONDecoder.DateDecodingStrategy {
    static var iso8601WithFractionalSeconds: Self {
        .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let d = MillisecondDate.parse(s) { return d }
            if let d = try? Date(s, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) { return d }
            if let d = try? Date(s, strategy: .iso8601) { return d }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(s)"))
        }
    }
}
