import Foundation

/// Offline import of a snapshot file into a `db.json`, for use while the app is not running
/// (see `TodoistImportCLITests`). The database goes through a `TodoStore` exactly like an
/// in-app import, and the next sync uploads the result.
public enum TodoistImportCLI {
    public enum Failure: LocalizedError {
        case databaseMissing(String)

        public var errorDescription: String? {
            switch self {
            case .databaseMissing(let p): "No database at \(p). Start TodoTim once (or check the path) before importing."
            }
        }
    }

    /// Loads `db` (refusing a missing or corrupt file), applies `snapshot`, saves when something
    /// changed and `dryRun` is false, and logs the report.
    @MainActor
    @discardableResult
    public static func run(snapshot: URL, db dbURL: URL, options: TodoistImportOptions = TodoistImportOptions(),
                           dryRun: Bool = false, log: (String) -> Void) throws -> ImportReport {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { throw Failure.databaseMissing(dbURL.path) }
        // Throws `PersistenceError.corrupt` (file moved aside) or `.unreadable`.
        let db = try LocalPersistence.loadChecked(from: dbURL)
        let snap = try TodoistSnapshot.load(from: snapshot)
        let store = TodoStore(db: db)
        let report = TodoistImport.apply(snap, to: store, options: options)
        log(report.summary)
        if dryRun {
            log("Dry run: \(dbURL.path) not changed.")
        } else if store.db != db {
            try LocalPersistence.save(store.db, to: dbURL)
            log("Saved \(dbURL.path).")
        } else {
            log("Nothing changed.")
        }
        return report
    }
}
