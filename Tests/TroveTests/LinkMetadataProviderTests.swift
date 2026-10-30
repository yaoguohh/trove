import Foundation
import Testing
@testable import Trove

struct LinkMetadataMigrationTests {
    @Test func legacyCacheWithoutPortStillDecodes() throws {
        let data = Data(#"{"url":"https://example.com","title":"Example","host":"example.com","iconFileName":null}"#.utf8)
        let metadata = try JSONDecoder().decode(LinkMetadata.self, from: data)
        #expect(metadata.host == "example.com")
        #expect(metadata.port == nil)
    }
}

struct HTMLEntityDecodingTests {
    @Test func decodesNamedEntities() {
        #expect(LinkMetadataProvider.decodeHTMLEntities("Tom &amp; Jerry") == "Tom & Jerry")
        #expect(LinkMetadataProvider.decodeHTMLEntities("a &lt; b &gt; c") == "a < b > c")
        #expect(LinkMetadataProvider.decodeHTMLEntities("say &quot;hi&quot;") == "say \"hi\"")
        #expect(LinkMetadataProvider.decodeHTMLEntities("it&apos;s") == "it's")
        #expect(LinkMetadataProvider.decodeHTMLEntities("a&nbsp;b") == "a\u{00A0}b")
    }

    @Test func decodesDecimalNumericEntities() {
        #expect(LinkMetadataProvider.decodeHTMLEntities("it&#39;s") == "it's")
        #expect(LinkMetadataProvider.decodeHTMLEntities("&#169; 2026") == "© 2026")
    }

    @Test func decodesHexNumericEntities() {
        #expect(LinkMetadataProvider.decodeHTMLEntities("it&#x27;s") == "it's")
        #expect(LinkMetadataProvider.decodeHTMLEntities("&#X1F600;") == "😀")
    }

    @Test func leavesPlainAndUnknownTextUntouched() {
        #expect(LinkMetadataProvider.decodeHTMLEntities("plain title") == "plain title")
        #expect(LinkMetadataProvider.decodeHTMLEntities("100% &unknownentity; ok") == "100% &unknownentity; ok")
        #expect(LinkMetadataProvider.decodeHTMLEntities("a & b") == "a & b")
    }
}

struct SSRFAddressClassificationTests {
    @Test func flagsPrivateAndReservedIPv4() {
        #expect(LinkMetadataProvider.isPrivateOrReserved(ip: "127.0.0.1"))
        #expect(LinkMetadataProvider.isPrivateOrReserved(ip: "10.1.2.3"))
        #expect(LinkMetadataProvider.isPrivateOrReserved(ip: "192.168.0.1"))
        #expect(LinkMetadataProvider.isPrivateOrReserved(ip: "172.16.0.1"))
        #expect(LinkMetadataProvider.isPrivateOrReserved(ip: "172.31.255.255"))
        #expect(LinkMetadataProvider.isPrivateOrReserved(ip: "169.254.169.254"))
        #expect(LinkMetadataProvider.isPrivateOrReserved(ip: "0.0.0.0"))
        #expect(LinkMetadataProvider.isPrivateOrReserved(ip: "100.64.0.1")) // CGNAT
    }

    @Test func allowsPublicIPv4() {
        #expect(!LinkMetadataProvider.isPrivateOrReserved(ip: "8.8.8.8"))
        #expect(!LinkMetadataProvider.isPrivateOrReserved(ip: "93.184.216.34"))
        #expect(!LinkMetadataProvider.isPrivateOrReserved(ip: "172.32.0.1"))
    }

    @Test func flagsPrivateAndReservedIPv6() {
        #expect(LinkMetadataProvider.isPrivateOrReserved(ip: "::1"))
        #expect(LinkMetadataProvider.isPrivateOrReserved(ip: "::"))
        #expect(LinkMetadataProvider.isPrivateOrReserved(ip: "fc00::1"))
        #expect(LinkMetadataProvider.isPrivateOrReserved(ip: "fd12:3456::1"))
        #expect(LinkMetadataProvider.isPrivateOrReserved(ip: "fe80::1"))
        #expect(LinkMetadataProvider.isPrivateOrReserved(ip: "::ffff:10.0.0.1")) // v4-mapped private
    }

    @Test func allowsPublicIPv6() {
        #expect(!LinkMetadataProvider.isPrivateOrReserved(ip: "2001:4860:4860::8888"))
    }

    @Test func rejectsEncodedAndNamedLoopbackHosts() {
        #expect(!LinkMetadataProvider.isAllowedHost("localhost"))
        #expect(!LinkMetadataProvider.isAllowedHost("printer.local"))
        #expect(!LinkMetadataProvider.isAllowedHost("127.0.0.1"))
        #expect(!LinkMetadataProvider.isAllowedHost("0x7f000001"))   // hex 127.0.0.1
        #expect(!LinkMetadataProvider.isAllowedHost("2130706433"))   // integer 127.0.0.1
        #expect(!LinkMetadataProvider.isAllowedHost("::1"))
        #expect(!LinkMetadataProvider.isAllowedHost("[::1]"))
        #expect(!LinkMetadataProvider.isAllowedHost(""))
    }

    @Test func allowsPublicHosts() {
        #expect(LinkMetadataProvider.isAllowedHost("example.com"))
        #expect(LinkMetadataProvider.isAllowedHost("8.8.8.8"))
        #expect(LinkMetadataProvider.isAllowedHost("github.com"))
    }
}

struct LinkMetadataNegativeCacheTests {
    private func empty(fetchedAt: Date?) -> LinkMetadata {
        LinkMetadata(url: "https://example.com", title: nil, host: "example.com", port: nil, iconFileName: nil, fetchedAt: fetchedAt)
    }

    @Test func emptyRecordExpiresAfterTheTTL() {
        let now = Date()
        #expect(LinkMetadataProvider.isStale(empty(fetchedAt: now.addingTimeInterval(-2 * 86_400)), now: now))
        #expect(!LinkMetadataProvider.isStale(empty(fetchedAt: now.addingTimeInterval(-60)), now: now))
    }

    @Test func legacyEmptyRecordWithoutTimestampCountsAsStale() {
        #expect(LinkMetadataProvider.isStale(empty(fetchedAt: nil), now: Date()))
    }

    @Test func recordsWithContentNeverExpire() {
        let old = Date(timeIntervalSinceNow: -365 * 86_400)
        var titled = empty(fetchedAt: old)
        titled.title = "Example"
        #expect(!LinkMetadataProvider.isStale(titled, now: Date()))
        var iconOnly = empty(fetchedAt: nil)
        iconOnly.iconFileName = "x-icon.png"
        #expect(!LinkMetadataProvider.isStale(iconOnly, now: Date()))
    }

    @Test func headEndIsDetectedCaseInsensitively() {
        let window = 16 * 1024
        #expect(LinkMetadataProvider.containsHeadEnd(Data("<html><head><title>x</title></HEAD><body>".utf8), lookingBackFrom: window))
        #expect(LinkMetadataProvider.containsHeadEnd(Data("<head></head>".utf8), lookingBackFrom: window))
        #expect(!LinkMetadataProvider.containsHeadEnd(Data("<html><head><title>x</title>".utf8), lookingBackFrom: window))
        // A marker straddling the window boundary is still found (the search looks back marker-length further).
        let padded = Data(repeating: 0x20, count: window - 3) + Data("</head>".utf8)
        #expect(LinkMetadataProvider.containsHeadEnd(padded, lookingBackFrom: window))
    }
}

actor ConcurrencyTracker {
    private(set) var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func exit() { current -= 1 }
}

struct AsyncSemaphoreTests {
    @Test func capsSimultaneousHolders() async {
        let gate = AsyncSemaphore(limit: 2)
        let tracker = ConcurrencyTracker()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await gate.acquire()
                    await tracker.enter()
                    try? await Task.sleep(nanoseconds: 15_000_000)
                    await tracker.exit()
                    await gate.release()
                }
            }
        }
        #expect(await tracker.peak <= 2)
        #expect(await tracker.peak >= 1)
        #expect(await tracker.current == 0)
    }
}
