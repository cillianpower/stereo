import Testing
import TunerModel
@testable import TunerRadio

@Suite struct StationSearchParserTests {
    @Test func plainWordsAreName() {
        let q = StationSearchParser.parse("radio paradise")
        #expect(q.name == "radio paradise")
        #expect(q.tags.isEmpty)
    }

    @Test func fullPowerQuery() {
        let q = StationSearchParser.parse("jazz codec:flac bitrate>=256 country:ie #chill tag:Lounge sort:votes")
        #expect(q.name == "jazz")
        #expect(q.codec == "FLAC")
        #expect(q.bitrateMin == 256)
        #expect(q.countryCode == "IE")
        #expect(q.tags == ["chill", "lounge"])
        #expect(q.order == .votes)
        #expect(q.reverse)
    }

    @Test func bitrateVariants() {
        #expect(StationSearchParser.parse("bitrate>128").bitrateMin == 129)
        #expect(StationSearchParser.parse("br<=96k").bitrateMax == 96)
        #expect(StationSearchParser.parse("kbps:320").bitrateMin == 320)
        #expect(StationSearchParser.parse("bitrate>=192kbps").bitrateMin == 192)
    }

    @Test func unknownPrefixFallsBackToName() {
        let q = StationSearchParser.parse("foo:bar country:Ireland")
        #expect(q.name == "foo:bar country:Ireland")
        #expect(q.countryCode == nil)
    }

    @Test func quotedPhrases() {
        #expect(StationSearchParser.tokenize(#""bbc radio 6" codec:aac"#) == ["bbc radio 6", "codec:aac"])
    }
}
