import Foundation
@testable import TodoCore

/// In-memory CalDAV server for sync tests: calendars with properties and sync tokens (RFC 6578
/// semantics: changes and removals since a token), objects with ETags and conditional writes.
actor FakeCalDAVServer: CalDAVServer {
    nonisolated let home: String

    struct Calendar {
        var props: RemoteCalendar
        var components = ["VTODO"]
        var sharedBy: String?
    }

    private(set) var calendarsByPath: [String: Calendar] = [:]
    private(set) var objects: [String: (etag: String, ics: String)] = [:]
    /// Version at which each object (or its removal) happened, per calendar.
    private var changeLog: [String: [String: (version: Int, removed: Bool)]] = [:]
    private var version = 0
    private var etagCounter = 0

    /// Request counts by method ("PROPFIND", "REPORT", "PUT", ...).
    private(set) var requests: [String: Int] = [:]
    private(set) var shares: [(path: String, user: String)] = []
    var failShares = false
    /// Called before each PUT; lets tests change an object "concurrently".
    var beforePut: (@Sendable (String) async -> Void)?
    /// Called once at the next calendar listing.
    var beforeList: (@Sendable () async -> Void)?

    init(user: String = "tim") { home = "calendars/\(user)" }

    // MARK: - Test helpers

    func addCalendar(_ uri: String, name: String? = nil, components: [String] = ["VTODO"], sharedBy: String? = nil,
                     sections: String? = nil, labels: String? = nil, color: String? = nil) {
        let path = "\(home)/\(uri)"
        calendarsByPath[path] = Calendar(props: RemoteCalendar(path: path, name: name ?? uri, color: color, order: "1",
                                                               sections: sections, labels: labels),
                                         components: components, sharedBy: sharedBy)
        changeLog[path] = [:]
        bump(path)
    }

    /// Writes an object directly (as another client would).
    @discardableResult
    func store(_ path: String, _ ics: String) -> String {
        etagCounter += 1
        let etag = "\"e\(etagCounter)\""
        objects[path] = (etag, ics)
        record(path, removed: false)
        return etag
    }

    func remove(_ path: String) {
        objects[path] = nil
        record(path, removed: true)
    }

    func setProperty(_ path: String, _ p: CalendarProperty, _ value: String?) {
        set(p, value, on: &calendarsByPath[path]!.props)
        bump(path)
    }

    func removeCalendar(_ path: String) {
        calendarsByPath[path] = nil
        for key in objects.keys where key.hasPrefix(path + "/") { objects[key] = nil }
    }

    func ics(_ path: String) -> String? { objects[path]?.ics }
    func paths(in calendar: String) -> [String] { objects.keys.filter { $0.hasPrefix(calendar + "/") }.sorted() }
    func count(_ method: String) -> Int { requests[method, default: 0] }
    func resetCounts() { requests = [:] }
    func setFailShares(_ v: Bool) { failShares = v }
    func setBeforePut(_ f: (@Sendable (String) async -> Void)?) { beforePut = f }
    func setBeforeList(_ f: (@Sendable () async -> Void)?) { beforeList = f }

    private func bump(_ calendar: String) {
        version += 1
        calendarsByPath[calendar]?.props.syncToken = "v\(version)"
    }

    private func record(_ path: String, removed: Bool) {
        let cal = String(path[..<path.lastIndex(of: "/")!])
        version += 1
        changeLog[cal, default: [:]][path] = (version, removed)
        calendarsByPath[cal]?.props.syncToken = "v\(version)"
    }

    private func set(_ p: CalendarProperty, _ value: String?, on props: inout RemoteCalendar) {
        switch p {
        case .name: props.name = value
        case .color: props.color = value
        case .order: props.order = value.map { String(Int((Double($0) ?? 0).rounded())) }  // Nextcloud stores an integer
        case .sections: props.sections = value
        case .labels: props.labels = value
        }
    }

    private func note(_ m: String) { requests[m, default: 0] += 1 }

    // MARK: - CalDAVServer

    func calendars() async throws -> [RemoteCalendar] {
        if let f = beforeList {
            beforeList = nil
            await f()
        }
        note("PROPFIND")
        return calendarsByPath.values.filter { $0.components == ["VTODO"] && $0.sharedBy == nil }.map(\.props)
    }

    func changes(in calendar: String, since token: String?) async throws -> CalendarChanges {
        note("REPORT")
        guard let cal = calendarsByPath[calendar] else { throw SyncError.notFound(calendar) }
        let since = token.flatMap { Int($0.dropFirst()) }
        var out = CalendarChanges(syncToken: cal.props.syncToken, changed: [], removed: [], isFull: since == nil)
        for (path, entry) in changeLog[calendar, default: [:]] where since == nil || entry.version > since! {
            if let o = objects[path] {
                out.changed.append(RemoteResource(path: path, etag: o.etag, ics: o.ics))
            } else if since != nil {
                out.removed.append(path)
            }
        }
        return out
    }

    func createCalendar(_ path: String, name: String, color: String, order: String) async throws {
        note("MKCALENDAR")
        guard calendarsByPath[path] == nil else { throw SyncError.calendarExists(path) }
        calendarsByPath[path] = Calendar(props: RemoteCalendar(path: path, name: name, color: color, order: order))
        changeLog[path] = [:]
        bump(path)
    }

    func setProperties(_ path: String, _ values: [CalendarProperty: String?]) async throws {
        note("PROPPATCH")
        guard calendarsByPath[path] != nil else { throw SyncError.notFound(path) }
        for (k, v) in values { set(k, v, on: &calendarsByPath[path]!.props) }
        bump(path)
    }

    func deleteCalendar(_ path: String) async throws {
        note("DELETE-CALENDAR")
        removeCalendar(path)
    }

    func share(_ path: String, with user: String) async throws {
        note("POST")
        if failShares { throw SyncError.forbidden(path) }
        shares.append((path, user))
    }

    func put(_ path: String, ics: String, ifMatch: String?) async throws -> String? {
        if let beforePut { await beforePut(path) }
        note("PUT")
        let cal = String(path[..<path.lastIndex(of: "/")!])
        guard calendarsByPath[cal] != nil else { throw SyncError.conflict(path) }
        switch (ifMatch, objects[path]) {
        case (nil, _?): throw SyncError.preconditionFailed(path)
        case (let m?, let o?) where o.etag != m: throw SyncError.preconditionFailed(path)
        case (_?, nil): throw SyncError.preconditionFailed(path)
        default: break
        }
        XCTAssertValid(ics)
        return store(path, ics)
    }

    func move(_ path: String, to destination: String, ifMatch: String?) async throws {
        note("MOVE")
        guard let o = objects[path] else { throw SyncError.notFound(path) }
        if let ifMatch, ifMatch != o.etag { throw SyncError.preconditionFailed(path) }
        guard objects[destination] == nil else { throw SyncError.preconditionFailed(destination) }
        remove(path)
        objects[destination] = o
        record(destination, removed: false)
    }

    func delete(_ path: String, ifMatch: String?) async throws {
        note("DELETE")
        guard let o = objects[path] else { return }
        if let ifMatch, ifMatch != o.etag { throw SyncError.preconditionFailed(path) }
        remove(path)
    }

    /// Every object TodoTim writes must parse and hold exactly one master VTODO.
    private func XCTAssertValid(_ ics: String) {
        guard let root = try? ICalendar.parse(ics), root.name == "VCALENDAR",
              root.components.filter({ $0.name == "VTODO" }).count >= 1 else {
            fatalError("invalid calendar object written:\n\(ics)")
        }
    }
}

/// Last-writer-wins merge of whole databases entity by entity, then `SyncEngine.clean` (what two
/// devices editing the same entities converge to).
func lwwMerge(_ dbs: [Database], now: Date) -> Database {
    func merge<T: SyncEntity>(_ dicts: [[EntityID: T]]) -> [EntityID: T] {
        var out: [EntityID: T] = [:]
        for d in dicts { for (id, e) in d { out[id] = out[id].map { SyncEngine.winner($0, e) } ?? e } }
        return out
    }
    var db = Database()
    db.projects = merge(dbs.map(\.projects))
    db.sections = merge(dbs.map(\.sections))
    db.tasks = merge(dbs.map(\.tasks))
    db.labels = merge(dbs.map(\.labels))
    return SyncEngine.clean(db, now: now)
}
