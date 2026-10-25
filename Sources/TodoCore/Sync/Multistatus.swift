import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Parses a WebDAV 207 Multi-Status body (PROPFIND, REPORT, PROPPATCH). Only properties inside a
/// propstat with a 2xx status are kept. Server XML is untrusted: DTDs and entities are refused,
/// and the number of responses and the length of any text are capped.
enum Multistatus {
    /// A property value: its text, and the child elements (qualified "namespace|name"); a child
    /// with a `name` attribute (CalDAV `<comp name="VTODO"/>`) is recorded as "namespace|name=VTODO".
    struct Property: Equatable, Sendable {
        var text: String = ""
        var children: [String] = []
    }

    struct Response: Equatable, Sendable {
        var href: String
        /// Status of the whole response (`<d:status>` outside propstat), e.g. 404 for a member
        /// removed since a sync token.
        var status: Int?
        /// Keyed by qualified name, e.g. "DAV:|displayname".
        var properties: [String: Property] = [:]

        func text(_ qname: String) -> String? { properties[qname]?.text }
    }

    struct Document: Equatable, Sendable {
        var responses: [Response]
        /// Top-level `<d:sync-token>` of a sync-collection REPORT.
        var syncToken: String?
    }

    enum Failure: Error {
        /// The document declares a DTD or entities (never needed for WebDAV; refused to rule out
        /// entity expansion).
        case dtd
        case tooManyEntries
        case textTooLong
    }

    /// Longest text of one element: room for one calendar object (`ICalendar.maxBytes`) as XML.
    static let maxTextLength = 2 * ICalendar.maxBytes

    /// nil if the body is not a DAV multistatus document.
    static func parse(_ data: Data, maxEntries: Int = SyncLimits.maxListingEntries) throws -> Document? {
        if data.range(of: Data("<!DOCTYPE".utf8)) != nil || data.range(of: Data("<!ENTITY".utf8)) != nil {
            throw Failure.dtd
        }
        let delegate = Delegate(maxEntries: maxEntries)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let ok = parser.parse()
        if let failure = delegate.failure { throw failure }
        guard ok, delegate.sawMultistatus else { return nil }
        return Document(responses: delegate.responses, syncToken: delegate.syncToken)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let maxEntries: Int
        var responses: [Response] = []
        var syncToken: String?
        var sawMultistatus = false
        var failure: Failure?

        init(maxEntries: Int) { self.maxEntries = maxEntries }

        private func fail(_ parser: XMLParser, _ f: Failure) {
            failure = f
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            fail(parser, .dtd)
        }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
            fail(parser, .dtd)
        }

        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
            fail(parser, .dtd)
            return nil
        }

        /// Element path below the document root, as qualified names.
        private var path: [String] = []
        private var text = ""
        private var href: String?
        private var responseStatus: Int?
        private var props: [String: Property] = [:]
        private var propstatProps: [String: Property] = [:]
        private var propstatOK = true
        /// The property being read (a direct child of `prop`).
        private var current: (name: String, value: Property)?

        private static func qname(_ name: String, _ ns: String?) -> String { "\(ns ?? "")|\(name)" }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let q = Self.qname(name, namespaceURI)
            path.append(q)
            text = ""
            switch q {
            case "DAV:|multistatus" where path.count == 1: sawMultistatus = true
            case "DAV:|response" where path.count == 2:
                href = nil; responseStatus = nil; props = [:]
            case "DAV:|propstat" where path.count == 3:
                propstatProps = [:]; propstatOK = true
            default:
                if path.count == 5, path[3] == "DAV:|prop" {
                    current = (q, Property())
                } else if path.count == 6, current != nil {
                    current!.value.children.append(attributes["name"].map { "\(q)=\($0)" } ?? q)
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard failure == nil else { return }
            text += string
            if text.utf8.count > Multistatus.maxTextLength { fail(parser, .textTooLong) }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { path.removeLast(); text = "" }
            let q = Self.qname(name, namespaceURI)
            let depth = path.count
            if depth == 5, let c = current, c.name == q {
                var value = c.value
                value.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                propstatProps[q] = value
                current = nil
                return
            }
            switch (q, depth) {
            case ("DAV:|sync-token", 2): syncToken = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case ("DAV:|href", 3) where href == nil: href = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case ("DAV:|status", 3): responseStatus = Self.statusCode(text)
            case ("DAV:|status", 4): propstatOK = Self.statusCode(text).map { (200...299).contains($0) } ?? false
            case ("DAV:|propstat", 3):
                if propstatOK { props.merge(propstatProps) { a, _ in a } }
            case ("DAV:|response", 2):
                guard let href else { break }
                if responses.count >= maxEntries { return fail(parser, .tooManyEntries) }
                responses.append(Response(href: href, status: responseStatus, properties: props))
            default: break
            }
        }

        /// "HTTP/1.1 200 OK" → 200.
        static func statusCode(_ s: String) -> Int? {
            let parts = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            return parts.count >= 2 ? Int(parts[1]) : nil
        }
    }
}
