import Testing
@testable import IlmekKit

@Suite("WordFilter")
struct WordFilterTests {
    @Test func masksWholeWordsAnyCase() {
        #expect(WordFilter.clean("Fuck this") == "••• this")
        #expect(WordFilter.clean("SİKTİR git") == "••• git")
        #expect(WordFilter.clean("orospuçocuğu") == "•••")
    }

    @Test func keepsInnocentWords() {
        for s in ["Ama yine de", "Sıkı çalış", "Kitap oku", "Amasya gezisi", "Malzeme al",
                  "Scunthorpe", "Siklamen sula", "Göteborg"] {
            #expect(WordFilter.clean(s) == s, "\(s)")
        }
    }

    @Test func keepsPunctuationAndEmoji() {
        #expect(WordFilter.clean("💧 Su iç, 8/8!") == "💧 Su iç, 8/8!")
        #expect(WordFilter.clean("shit!") == "•••!")
        #expect(WordFilter.clean("") == "")
    }
}
