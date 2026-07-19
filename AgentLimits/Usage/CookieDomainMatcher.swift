import Foundation

/// Matches an HTTP cookie domain against an expected registrable domain.
///
/// Cookie domains may start with a dot and may name a legitimate subdomain,
/// but a bare string suffix is unsafe: `evilclaude.ai` is not a subdomain of
/// `claude.ai`.
enum CookieDomainMatcher {
    static func matches(_ cookieDomain: String, expectedDomain: String) -> Bool {
        let candidate = normalize(cookieDomain)
        let expected = normalize(expectedDomain)
        guard !candidate.isEmpty, !expected.isEmpty else { return false }
        return candidate == expected || candidate.hasSuffix(".\(expected)")
    }

    private static func normalize(_ domain: String) -> String {
        domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }
}
