import Foundation
import Testing
@testable import Trove

/// `LinkCardText.make` is the pure, network-free derivation behind the link card: it turns the raw
/// copied URL (+ any fetched metadata) into the three strings the card shows — a hero line, an
/// always-on route line, and a host footer. The whole point is that two links to the SAME host must
/// never collapse to identical cards, in BOTH the no-title and title-fetched states.
struct LinkCardTextTests {
    private func make(
        _ url: String,
        title: String? = nil,
        host metaHost: String? = nil,
        port metaPort: Int? = nil
    ) -> LinkCardText {
        let metadata = (title != nil || metaHost != nil || metaPort != nil)
            ? LinkMetadata(url: url, title: title, host: metaHost ?? "", port: metaPort, iconFileName: nil)
            : nil
        return LinkCardText.make(rawURL: url, metadata: metadata)
    }

    // MARK: - The reported bug: same-host deep links must be distinguishable

    @Test func deepLinkSurfacesPathTailAndRoute() {
        let d = make("https://github.com/anthropics/claude-code/issues/1234")
        #expect(d.host == "github.com")
        #expect(d.route == "/anthropics/claude-code/issues/1234")
        #expect(d.primary == "issues/1234")
        #expect(d.primaryIsTitle == false)
    }

    @Test func twoSameHostDeepLinksDifferOnBothLines() {
        let a = make("https://github.com/anthropics/claude-code/issues/1234")
        let b = make("https://github.com/anthropics/claude-code/pull/9876")
        #expect(a.host == b.host)          // same site — correct
        #expect(a.primary != b.primary)    // "issues/1234" vs "pull/9876"
        #expect(a.route != b.route)        // distinct routes
    }

    // MARK: - Root URLs collapse to host, no route line, no empty gap

    @Test func bareRootHasNoRouteAndHostHero() {
        let d = make("https://github.com")
        #expect(d.route == nil)
        #expect(d.primary == "github.com")
        #expect(d.primaryIsTitle == false)
    }

    @Test func trailingSlashRootMatchesBareRoot() {
        #expect(make("https://github.com/").route == nil)
        #expect(make("https://github.com/").primary == "github.com")
    }

    @Test func trailingSlashOnDeepPathIsNormalizedOff() {
        let d = make("https://example.com/a/b/c/")
        #expect(d.route == "/a/b/c")
        #expect(d.primary == "b/c")
        #expect(d.host == "example.com")
    }

    // MARK: - Title path is not regressed; route still disambiguates

    @Test func fetchedTitleBecomesHeroButRouteRemains() {
        let d = make(
            "https://github.com/anthropics/claude-code/issues/1234",
            title: "Fix paste bug · Issue #1234",
            host: "github.com"
        )
        #expect(d.primary == "Fix paste bug · Issue #1234")
        #expect(d.primaryIsTitle == true)
        #expect(d.route == "/anthropics/claude-code/issues/1234")
    }

    @Test func identicalTemplatedTitlesStillDifferOnRoute() {
        let a = make("https://github.com/anthropics/claude-code/pull/9876", title: "Pull Request · GitHub", host: "github.com")
        let b = make("https://github.com/anthropics/claude-code/pull/4242", title: "Pull Request · GitHub", host: "github.com")
        #expect(a.primary == b.primary)    // same templated title
        #expect(a.route != b.route)        // …but the route line still tells them apart
    }

    @Test func rootURLWithTitleHasNoRoute() {
        let d = make("https://github.com", title: "GitHub", host: "github.com")
        #expect(d.primary == "GitHub")
        #expect(d.primaryIsTitle == true)
        #expect(d.route == nil)
    }

    @Test func whitespaceOnlyTitleIsTreatedAsAbsent() {
        let d = make("https://github.com/anthropics/claude-code/issues/1234", title: "   ", host: "github.com")
        #expect(d.primaryIsTitle == false)
        #expect(d.primary == "issues/1234")
    }

    @Test func metadataHostOverridesParsedHost() {
        let d = make("https://raw.example.com/x", host: "redirected.example.com")
        #expect(d.host == "redirected.example.com")
    }

    @Test func redirectedMetadataHostDoesNotReuseSourcePort() {
        let d = make("https://source.example.com:8443/x", host: "redirected.example.com")
        #expect(d.host == "redirected.example.com")
    }

    @Test func redirectedMetadataUsesItsOwnPort() {
        let d = make("https://source.example.com:8443/x", host: "redirected.example.com", port: 9443)
        #expect(d.host == "redirected.example.com:9443")
    }

    @Test func legacyMetadataOnSameHostKeepsSourcePort() {
        let d = make("https://www.example.com:8443/x", host: "example.com")
        #expect(d.host == "example.com:8443")
    }

    // MARK: - Query disambiguation

    @Test func youtubeWatchPromotesVideoID() {
        let d = make("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(d.host == "youtube.com")              // www stripped
        #expect(d.primary == "dQw4w9WgXcQ")
        #expect(d.route == "/watch?v=dQw4w9WgXcQ")
    }

    @Test func hackerNewsItemPromotesID() {
        let d = make("https://news.ycombinator.com/item?id=12345")
        #expect(d.primary == "12345")
        #expect(d.route == "/item?id=12345")
        #expect(d.host == "news.ycombinator.com")
    }

    @Test func trackingParamIsSkippedForRealDiscriminator() {
        let d = make("https://a.com/search?utm=x&q=real")
        #expect(d.primary == "real")                  // not the utm value "x"
        #expect(d.host == "a.com")
    }

    @Test func emptyQueryValueFallsBackToVerbSegment() {
        let d = make("https://www.youtube.com/watch?v=")
        #expect(d.primary == "watch")                 // no usable discriminator
        #expect(d.route == "/watch?v=")
    }

    @Test func onlyQueryRootPromotesValueToHero() {
        let d = make("https://example.com/?q=apple")
        #expect(d.primary == "apple")
        #expect(d.route == "/?q=apple")
        #expect(d.host == "example.com")
    }

    @Test func deepPathKeepsNonTrackingQueryDiscriminator() {
        let red = make("https://example.com/products/detail?color=red&utm_source=newsletter")
        let blue = make("https://example.com/products/detail?color=blue&utm_source=newsletter")
        #expect(red.route == "/products/detail?color=red")
        #expect(blue.route == "/products/detail?color=blue")
        #expect(red.route != blue.route)
    }

    @Test func trackingOnlyQueryDoesNotCreateRouteNoise() {
        #expect(make("https://example.com/?utm_source=newsletter&gclid=abc").route == nil)
        #expect(make("https://example.com/products/detail?utm_campaign=sale").route == "/products/detail")
    }

    @Test func percentEncodedTrackingKeyIsFiltered() {
        let d = make("https://example.com/products?%75tm_source=newsletter&color=red")
        #expect(d.route == "/products?color=red")
    }

    @Test func spaFragmentRoutePromotesLastFragmentSegment() {
        let d = make("https://example.com/#/dashboard")
        #expect(d.primary == "dashboard")
        #expect(d.route == "/#/dashboard")
    }

    // MARK: - Robust parsing (the adversarial-critique fixes)

    @Test func fragmentSurvivesOnDeepPath() {
        let d = make("https://example.com/path/to/page#diff-abc")
        #expect(d.route == "/path/to/page#diff-abc")
        #expect(d.primary == "to/page")
    }

    @Test func idnHostIsDecodedNotPunycode() {
        let d = make("https://münchen.de/straße")
        #expect(d.host == "münchen.de")
        #expect(d.route == "/straße")
        #expect(d.primary == "straße")
    }

    @Test func percentEncodedPathIsDecodedForReadability() {
        let d = make("https://example.com/%E3%83%91%E3%82%B9")
        #expect(d.route == "/パス")
        #expect(d.primary == "パス")
    }

    @Test func encodedSlashDoesNotCollideWithRealSlash() {
        // %2F is a literal char inside one segment, NOT a path separator: the two URLs are different
        // resources and must render different routes (the design's central guarantee).
        let encoded = make("https://example.com/foo%2Fbar/baz")
        let real = make("https://example.com/foo/bar/baz")
        #expect(encoded.route == "/foo%2Fbar/baz")
        #expect(real.route == "/foo/bar/baz")
        #expect(encoded.route != real.route)
    }

    @Test func encodedPercentSlashDoesNotCollideWithEncodedSlash() {
        let encodedPercent = make("https://example.com/foo%252Fbar")
        let encodedSlash = make("https://example.com/foo%2Fbar")
        #expect(encodedPercent.route == "/foo%252Fbar")
        #expect(encodedSlash.route == "/foo%2Fbar")
        #expect(encodedPercent.route != encodedSlash.route)
    }

    @Test func privateUseScalarDecodesWithoutSentinelCollision() {
        let d = make("https://example.com/%EF%A3%BF/value")
        #expect(d.route == "/\u{F8FF}/value")
        #expect(d.primary == "\u{F8FF}/value")
    }

    @Test func doubledSlashesStayVisibleInRoute() {
        let doubled = make("https://example.com//double//slash//")
        let single = make("https://example.com/double/slash")
        #expect(doubled.route != single.route)        // extra slashes preserved → distinguishable
    }

    @Test func userinfoStrippedPortKept() {
        let d = make("http://user:pass@example.com:8080/admin/users")
        #expect(d.host == "example.com:8080")         // credentials never shown
        #expect(d.primary == "admin/users")
        #expect(d.route == "/admin/users")
    }

    @Test func localhostDevLinkKeepsPort() {
        let d = make("http://127.0.0.1:3000/admin/users")
        #expect(d.host == "127.0.0.1:3000")
        #expect(d.route == "/admin/users")
    }

    @Test func longOrgRepoKeepsOrgSoForksDiffer() {
        // A 41-char repo name shared by two orgs must NOT collapse to just the repo (which would
        // re-introduce the original bug for the org/repo shape).
        let repo = String(repeating: "x", count: 41)
        let a = make("https://github.com/anthropics/\(repo)")
        let b = make("https://github.com/microsoft/\(repo)")
        #expect(a.primary != b.primary)
        #expect(a.primary == "anthropics/\(repo)")
    }

    // MARK: - Degenerate input never crashes or fabricates a host

    @Test func malformedInputShowsRawTextNoFabricatedHost() {
        let d = make("https:// not a url")
        #expect(d.route == nil)
        #expect(d.host == "")
        #expect(d.primary == "https:// not a url")
    }

    @Test func emptyStringFallsBackToLink() {
        let d = make("")
        #expect(d.primary == "Link")
        #expect(d.route == nil)
        #expect(d.host == "")
    }
}
