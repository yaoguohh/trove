import Testing
@testable import ClipDeck

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
