# Shared fixtures

Golden data checked by both the Swift tests (`Tests/TodoCoreTests`) and the Kotlin tests
(`android/core/src/test`). A behaviour change updates the fixture and both implementations together.

## urls

`urls.json`: the URL rules of `WebDAVClient` (docs/caldav.md, "Limits"): what a server URL may be, how a
relative path becomes a request URL, and which hrefs from a server are accepted. Checked by the Kotlin tests
(`dav/UrlFixturesTest`); the Swift `WebDAVClientTests` cover the same cases inline.

- `baseURL`: `normalizedBaseURL`.
  - `valid`: `{ "input", "normalized" }`; the input is accepted and normalized to that URL (trailing slash).
  - `insecure`: plain http:// to a host other than localhost; refused as insecure.
  - `invalid`: refused as an invalid URL (no scheme or host, credentials, query, fragment, other schemes).
- `requestPath`: `url(for:)` on a client with server URL `base`.
  - `encoded`: `{ "path", "collection", "url" }`; the path (decoded, relative to `base`) gives that URL.
  - `refused`: paths with empty, "." or ".." segments; refused without sending a request.
- `href`: `relativePath(ofHref:)` on a client with server URL `base`: `{ "href", "path" }`, where `path` is the
  decoded path relative to `base`, or `null` when the href is refused (another origin, outside `base`, a
  segment that is or decodes to "." or "..", or one that decodes to "/").
