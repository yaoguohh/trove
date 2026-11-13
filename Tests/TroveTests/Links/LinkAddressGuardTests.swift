import Foundation
import Testing
@testable import Trove

struct SSRFAddressClassificationTests {
    @Test func flagsPrivateAndReservedIPv4() {
        #expect(LinkAddressGuard.isPrivateOrReserved(ip: "127.0.0.1"))
        #expect(LinkAddressGuard.isPrivateOrReserved(ip: "10.1.2.3"))
        #expect(LinkAddressGuard.isPrivateOrReserved(ip: "192.168.0.1"))
        #expect(LinkAddressGuard.isPrivateOrReserved(ip: "172.16.0.1"))
        #expect(LinkAddressGuard.isPrivateOrReserved(ip: "172.31.255.255"))
        #expect(LinkAddressGuard.isPrivateOrReserved(ip: "169.254.169.254"))
        #expect(LinkAddressGuard.isPrivateOrReserved(ip: "0.0.0.0"))
        #expect(LinkAddressGuard.isPrivateOrReserved(ip: "100.64.0.1")) // CGNAT
    }

    @Test func allowsPublicIPv4() {
        #expect(!LinkAddressGuard.isPrivateOrReserved(ip: "8.8.8.8"))
        #expect(!LinkAddressGuard.isPrivateOrReserved(ip: "93.184.216.34"))
        #expect(!LinkAddressGuard.isPrivateOrReserved(ip: "172.32.0.1"))
    }

    @Test func flagsPrivateAndReservedIPv6() {
        #expect(LinkAddressGuard.isPrivateOrReserved(ip: "::1"))
        #expect(LinkAddressGuard.isPrivateOrReserved(ip: "::"))
        #expect(LinkAddressGuard.isPrivateOrReserved(ip: "fc00::1"))
        #expect(LinkAddressGuard.isPrivateOrReserved(ip: "fd12:3456::1"))
        #expect(LinkAddressGuard.isPrivateOrReserved(ip: "fe80::1"))
        #expect(LinkAddressGuard.isPrivateOrReserved(ip: "::ffff:10.0.0.1")) // v4-mapped private
    }

    @Test func allowsPublicIPv6() {
        #expect(!LinkAddressGuard.isPrivateOrReserved(ip: "2001:4860:4860::8888"))
    }

    @Test func rejectsEncodedAndNamedLoopbackHosts() {
        #expect(!LinkAddressGuard.isAllowedHost("localhost"))
        #expect(!LinkAddressGuard.isAllowedHost("printer.local"))
        #expect(!LinkAddressGuard.isAllowedHost("127.0.0.1"))
        #expect(!LinkAddressGuard.isAllowedHost("0x7f000001"))   // hex 127.0.0.1
        #expect(!LinkAddressGuard.isAllowedHost("2130706433"))   // integer 127.0.0.1
        #expect(!LinkAddressGuard.isAllowedHost("::1"))
        #expect(!LinkAddressGuard.isAllowedHost("[::1]"))
        #expect(!LinkAddressGuard.isAllowedHost(""))
    }

    @Test func allowsPublicHosts() {
        #expect(LinkAddressGuard.isAllowedHost("example.com"))
        #expect(LinkAddressGuard.isAllowedHost("8.8.8.8"))
        #expect(LinkAddressGuard.isAllowedHost("github.com"))
    }
}
