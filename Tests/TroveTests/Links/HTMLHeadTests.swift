import Foundation
import Testing
@testable import Trove

struct HTMLEntityDecodingTests {
    @Test func decodesNamedEntities() {
        #expect(HTMLHead.decodeEntities("Tom &amp; Jerry") == "Tom & Jerry")
        #expect(HTMLHead.decodeEntities("a &lt; b &gt; c") == "a < b > c")
        #expect(HTMLHead.decodeEntities("say &quot;hi&quot;") == "say \"hi\"")
        #expect(HTMLHead.decodeEntities("it&apos;s") == "it's")
        #expect(HTMLHead.decodeEntities("a&nbsp;b") == "a\u{00A0}b")
    }

    @Test func decodesDecimalNumericEntities() {
        #expect(HTMLHead.decodeEntities("it&#39;s") == "it's")
        #expect(HTMLHead.decodeEntities("&#169; 2026") == "© 2026")
    }

    @Test func decodesHexNumericEntities() {
        #expect(HTMLHead.decodeEntities("it&#x27;s") == "it's")
        #expect(HTMLHead.decodeEntities("&#X1F600;") == "😀")
    }

    @Test func leavesPlainAndUnknownTextUntouched() {
        #expect(HTMLHead.decodeEntities("plain title") == "plain title")
        #expect(HTMLHead.decodeEntities("100% &unknownentity; ok") == "100% &unknownentity; ok")
        #expect(HTMLHead.decodeEntities("a & b") == "a & b")
    }
}

struct HTMLHeadEndTests {
    @Test func headEndIsDetectedCaseInsensitively() {
        let window = 16 * 1024
        #expect(HTMLHead.containsEnd(Data("<html><head><title>x</title></HEAD><body>".utf8), lookingBackFrom: window))
        #expect(HTMLHead.containsEnd(Data("<head></head>".utf8), lookingBackFrom: window))
        #expect(!HTMLHead.containsEnd(Data("<html><head><title>x</title>".utf8), lookingBackFrom: window))
        // A marker straddling the window boundary is still found (the search looks back marker-length further).
        let padded = Data(repeating: 0x20, count: window - 3) + Data("</head>".utf8)
        #expect(HTMLHead.containsEnd(padded, lookingBackFrom: window))
    }
}
