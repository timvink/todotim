import AppKit
import SwiftUI

/// Renders task titles and description lines like Todoist: inline Markdown (`[text](url)`,
/// `**bold**`, `*italic*`, `` `code` ``) and bare http(s) URLs as underlined links.
///
/// Results are cached per source string, so scrolling and j/k never re-parse. Strings without
/// any Markdown or URL characters skip parsing entirely. The stored text is never changed:
/// editors show the raw Markdown and search matches the raw text.
@MainActor
enum RichText {
    /// Only these link schemes are kept (and opened); others render as plain text.
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    private static var cache: [String: AttributedString] = [:]
    private static let cacheLimit = 5000
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func render(_ source: String) -> AttributedString {
        if let hit = cache[source] { return hit }
        let value = parse(source)
        // Crude bound: the working set is the tasks on screen plus recent ones.
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[source] = value
        return value
    }

    private static func parse(_ source: String) -> AttributedString {
        let hasMarkup = source.contains { "[*_`~".contains($0) }
        let hasURL = source.contains("http") || source.contains("mailto:") || source.contains("www.")
        guard hasMarkup || hasURL else { return AttributedString(source) }

        var out = (hasMarkup ? try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        ) : nil) ?? AttributedString(source)

        // Drop links with other schemes (e.g. file:, javascript:).
        for run in out.runs {
            if let url = run.link, !isAllowed(url) { out[run.range].link = nil }
        }
        // Bare URLs in text that is not already a link.
        if hasURL, let detector {
            let plain = String(out.characters)
            let ns = plain as NSString
            for m in detector.matches(in: plain, range: NSRange(location: 0, length: ns.length)) {
                guard let url = m.url, isAllowed(url),
                      let r = Range(m.range, in: out), out[r].runs.allSatisfy({ $0.link == nil }) else { continue }
                out[r].link = url
            }
        }
        for run in out.runs where run.link != nil {
            out[run.range].underlineStyle = .single
        }
        return out
    }

    static func isAllowed(_ url: URL) -> Bool {
        allowedSchemes.contains(url.scheme?.lowercased() ?? "")
    }

    /// Opens allowed links in the default browser / mail app; ignores everything else.
    static let openAction = OpenURLAction { url in
        guard isAllowed(url) else { return .discarded }
        NSWorkspace.shared.open(url)
        return .handled
    }
}

extension View {
    /// Link styling for `RichText`: links keep the surrounding text color (underlined only), and
    /// only http/https/mailto links open.
    func richTextLinks(tint: Color) -> some View {
        self.tint(tint).environment(\.openURL, RichText.openAction)
    }
}
