import Foundation
import Testing
@testable import AidesCore

struct ToolkitSourceTests {
    @Test func publicSourceURLsRejectLocalHostsCredentialsAndUnusualPorts() {
        #expect(ToolkitSourceAddress.httpsURL("https://News.Example.org:443/feed")?.absoluteString ==
                "https://news.example.org/feed")
        for rejected in [
            "http://news.example.org/feed", "https://user:secret@news.example.org/feed",
            "https://news.example.org:8443/feed", "https://news.example.org/feed#fragment",
            "https://localhost/feed", "https://127.0.0.1/feed", "https://[::1]/feed",
            "https://replay.local/feed", "https://device.home.arpa/feed", "https://-bad.example.org/"
        ] {
            #expect(ToolkitSourceAddress.httpsURL(rejected) == nil, "\(rejected)")
        }
    }

    @Test func addressPolicyRejectsNonPublicIPv4Ranges() {
        let rejected: [UInt32] = [
            0x00000000, 0x0a000001, 0x64400001, 0x647fffff, 0x7f000001, 0xa9fea9fe,
            0xac100001, 0xac1fffff, 0xc0000001, 0xc0000201, 0xc0586301, 0xc0a80001,
            0xc6120001, 0xc6130001, 0xc6336401, 0xcb007101, 0xe0000001, 0xffffffff,
        ]
        for address in rejected { #expect(!ToolkitSourceAddress.isPublicIPv4(address)) }
        #expect(ToolkitSourceAddress.isPublicIPv4(0x01010101))
        #expect(ToolkitSourceAddress.isPublicIPv4(0x08080808))
        #expect(ToolkitSourceAddress.isPublicIPv4(0xac200001))
    }

    @Test func rssEntriesRetainOrderAndDeduplicateIDs() throws {
        let xml = """
        <rss version="2.0"><channel>
          <item><title>  Research &amp; tools  </title><guid>fixture-a</guid>
            <link>https://news.example.org/a</link></item>
          <item><title>Duplicate</title><guid>fixture-a</guid></item>
          <item><title><![CDATA[Second item]]></title><guid>fixture-b</guid>
            <link>file:///private/restricted</link></item>
        </channel></rss>
        """
        let result = try #require(ToolkitFeedDocument.entries(Data(xml.utf8)))
        #expect(result.map(\.title) == ["Research & tools", "Second item"])
        #expect(result.map(\.url) == ["https://news.example.org/a", nil])
        #expect(result.map(\.id) == ["fixture-a", "fixture-b"].map { ToolkitFeedDocument.fingerprint(Data($0.utf8)) })
    }

    @Test func atomEntriesPreferAlternateLinksAndCollectText() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry><title type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">Draft <b>agenda</b></div></title>
            <id>atom-id</id><link rel="self" href="https://news.example.org/self"/>
            <link rel="alternate" href="https://news.example.org/view"/></entry>
        </feed>
        """
        let result = try #require(ToolkitFeedDocument.entries(Data(xml.utf8)))
        #expect(result.count == 1)
        #expect(result.first?.title == "Draft agenda")
        #expect(result.first?.url == "https://news.example.org/view")
    }

    @Test func feedParserRejectsDTDAndInvalidDocuments() {
        for xml in [
            "<!DOCTYPE rss SYSTEM \"file:///private/restricted\"><rss/>", "<html/>",
            "<rss><channel><item><title>Incomplete</title></item>",
        ] {
            #expect(ToolkitFeedDocument.entries(Data(xml.utf8)) == nil)
        }
        #expect(ToolkitFeedDocument.entries(Data(repeating: 65, count: ToolkitFeedDocument.maxBytes + 1)) == nil)
    }
}
