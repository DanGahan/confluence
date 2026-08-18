import Testing
@testable import ConfluenceKit

/// Repays G5 (#121): Mastodon HTML → text now decodes numeric/hex character references and
/// tolerates real-world tag variants, not just a fixed 7-entity list.
struct HTMLTextTests {
    @Test func namedEntitiesDecode() {
        #expect(htmlToPlainText("<p>Hello &amp; welcome</p>") == "Hello & welcome")
        #expect(htmlToPlainText("<p>1 &lt; 2 &gt; 0 &quot;q&quot;</p>") == "1 < 2 > 0 \"q\"")
    }

    @Test func decimalAndHexReferencesDecode() {
        #expect(htmlToPlainText("<p>it&#8217;s</p>") == "it\u{2019}s")        // curly apostrophe
        #expect(htmlToPlainText("<p>a &#8212; b</p>") == "a \u{2014} b")       // em dash
        #expect(htmlToPlainText("<p>hi &#x1F600;</p>") == "hi \u{1F600}")      // emoji via hex
    }

    @Test func unknownOrBareAmpersandsSurvive() {
        #expect(htmlToPlainText("<p>AT&T rocks</p>") == "AT&T rocks")
        #expect(htmlToPlainText("<p>5 &notareal; x</p>") == "5 &notareal; x")
        #expect(htmlToPlainText("<p>a &amp b</p>") == "a &amp b")             // missing semicolon
    }

    @Test func lineAndParagraphBreaks() {
        #expect(htmlToPlainText("<p>a<br class=\"x\">b</p>") == "a\nb")        // <br> with attrs
        #expect(htmlToPlainText("x<BR/>y") == "x\ny")                          // uppercase, self-closing
        #expect(htmlToPlainText("<p>one</p><p>two</p>") == "one\n\ntwo")       // paragraphs
        #expect(htmlToPlainText("a&nbsp;b") == "a b")
    }
}
