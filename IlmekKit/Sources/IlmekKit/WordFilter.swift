import Foundation

/// Masks offensive words in text that comes from other people (nicknames, habit and group names).
/// App Store guideline 1.2: apps that show user-generated content need a way to filter it.
///
/// Words are matched whole (case-insensitive, Turkish-aware lowercasing), and a few long stems are
/// matched as word prefixes so inflected Turkish forms are caught too. Short stems are deliberately
/// not prefix-matched: "am", "sik" would hit innocent words ("ama", "sıkı").
public enum WordFilter {
    static let words: Set<String> = [
        // Turkish
        "amk", "aq", "amq", "sik", "sikik", "sikerim", "yarak", "yarrak", "göt", "götveren", "piç",
        "orospu", "oç", "pezevenk", "kahpe", "ibne", "gavat", "kaltak", "sürtük", "amcık", "taşak",
        "salak", "gerizekalı", "şerefsiz", "yavşak", "puşt",
        // English
        "fuck", "fucker", "fucking", "shit", "bitch", "cunt", "dick", "cock", "pussy", "asshole",
        "bastard", "whore", "slut", "nigger", "nigga", "faggot", "retard", "motherfucker",
    ]
    /// Matched as the start of a word (≥ 5 letters each, so they don't hit ordinary words).
    static let stems = ["orospu", "siktir", "sikey", "sikiş", "yarrak", "amına", "amcık", "pezeven",
                        "şerefsiz", "gerizekal", "fucki", "motherf", "bitche"]

    public static let mask = "•••"

    public static func clean(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = ""
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            out += isOffensive(word) ? mask : word
            word = ""
        }
        for ch in text {
            if ch.isLetter || ch.isNumber {
                word.append(ch)
            } else {
                flush()
                out.append(ch)
            }
        }
        flush()
        return out
    }

    public static func isOffensive(_ word: String) -> Bool {
        let w = word.lowercased(with: Locale(identifier: "tr_TR"))
        if words.contains(w) { return true }
        return stems.contains { w.hasPrefix($0) }
    }
}
