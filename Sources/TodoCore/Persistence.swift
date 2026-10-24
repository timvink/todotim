import Foundation

/// Local database file: ~/Library/Application Support/TodoTim/db.json
public enum LocalPersistence {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TodoTim", isDirectory: true)
    }

    public static var fileURL: URL { directory.appendingPathComponent("db.json") }

    public static func load(from url: URL = fileURL) -> Database {
        guard let data = try? Data(contentsOf: url) else { return Database() }
        return (try? JSONCoding.decoder.decode(Database.self, from: data)) ?? Database()
    }

    public static func save(_ db: Database, to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(db).write(to: url, options: .atomic)
    }
}

public enum JSONCoding {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601WithFractionalSeconds
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601WithFractionalSeconds
        return d
    }
}

extension JSONEncoder.DateEncodingStrategy {
    static var iso8601WithFractionalSeconds: Self {
        .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))
        }
    }
}

extension JSONDecoder.DateDecodingStrategy {
    static var iso8601WithFractionalSeconds: Self {
        .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let d = try? Date(s, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) { return d }
            if let d = try? Date(s, strategy: .iso8601) { return d }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(s)"))
        }
    }
}
