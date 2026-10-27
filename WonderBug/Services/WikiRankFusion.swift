import Foundation

/// The frozen offline experiment's RRF policy, with the same 20-passage inference budget.
nonisolated enum WikiRankFusion {
    static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    static func ranking(_ lists: [[String]], available: Set<String>) -> [String] {
        var scores: [String: Double] = [:]
        for list in lists {
            for (offset, id) in unique(list).enumerated() where available.contains(id) {
                scores[id, default: 0] += 1 / Double(61 + offset)
            }
        }
        return scores.keys.sorted {
            scores[$0]! == scores[$1]! ? $0 < $1 : scores[$0]! > scores[$1]!
        }
    }

    static func shortlist(article: [String], body: [String], dense: [String],
                          prepared: [String: WikiEvidenceRecord]) -> [String] {
        let available = Set(prepared.keys)
        let lexical = ranking([article, body], available: available)
        let ordered = ranking([lexical, dense], available: available)
        var seen = Set<String>()
        return Array(ordered.filter { id in
            let key = prepared[id]!.text.split(whereSeparator: \.isWhitespace)
                .joined(separator: " ").folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            return seen.insert(key).inserted
        }.prefix(20))
    }
}
