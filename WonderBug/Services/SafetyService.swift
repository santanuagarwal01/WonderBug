//
//  SafetyService.swift
//  WonderBug
//

import Foundation

/// A blocked question never reaches the model and a blocked answer is never shown; both are
/// replaced by `SafetyService.blockedResponse`.
enum SafetyVerdict {
    case allowed
    case blocked
}

protocol SafetyServicing {
    func evaluate(_ text: String) -> SafetyVerdict
    func evaluateAnswer(_ answer: String) -> SafetyVerdict
    func isBareFollowUp(_ question: String) -> Bool
    func safePassage(_ passage: String) -> String?
}

/// Rule-based content gate, independent of the model. The lists are deliberately conservative and
/// should be extended, never loosened.
struct SafetyService: SafetyServicing {

    static let blockedResponse = "I'm not sure about that — let's ask your grown-up!"

    /// What a young child should not be read even in passing, so it is screened in questions,
    /// retrieved passages and answers alike. Matched as whole words only ("kill" never trips on
    /// "skill"), so inflected forms are listed.
    private static let graphicWords: Set<String> = [
        // violence, weapons
        "gun", "guns", "knife", "knives", "weapon", "weapons",
        "kill", "kills", "killing", "killed", "killer", "killers",
        "murder", "murders", "murdering", "murdered", "murderer", "murderers",
        "assault", "assaults", "assaulted",
        "bomb", "bombs", "bombing", "explosive", "explosives",
        "shoot", "shooting", "shootings", "shooter", "shooters",
        "stab", "stabs", "stabbing", "stabbed",
        "torture", "tortures", "torturing", "tortured",
        "assassin", "assassins", "assassinate", "assassinated", "assassination",
        "massacre", "massacres", "genocide",
        "terrorist", "terrorists", "terrorism",
        "hostage", "hostages",
        "kidnap", "kidnaps", "kidnapped", "kidnapping",
        "strangle", "strangled", "strangling",
        "execution", "executed", "lynch", "lynched", "lynching",
        // sexual topics
        "sex", "porn", "pornography", "pornographic", "sexual", "naked", "nude", "nudity",
        "orgasm", "orgasms", "masturbate", "masturbation", "intercourse", "erotic", "fetish",
        "prostitute", "prostitution", "stripper", "strippers", "hooker", "hookers",
        "rape", "raped", "molest", "molested", "molesting",
        // abuse
        "abuse", "abused", "abusing", "abuser",
        // bodies
        "corpse", "corpses", "cadaver", "cadavers",
        "decapitate", "decapitated", "decapitation",
        "mutilate", "mutilated", "mutilation",
        "gore", "gory", "autopsy", "autopsies",
        // adult substances
        "alcohol", "beer", "wine", "whiskey", "vodka", "rum", "tequila", "liquor",
        "drunk", "drunken", "intoxicated",
        "drug", "drugs", "marijuana", "cannabis", "cocaine", "heroin", "meth", "methamphetamine",
        "opioid", "opioids", "nicotine", "tobacco",
        "cigarette", "cigarettes", "cigar", "cigars", "vape", "vapes", "vaping",
        "overdose", "overdosed", "addiction", "addicted", "addict", "addicts"
    ]

    /// Blocked in the child's question only. In encyclopedia text these words are ordinary history
    /// and biology — "war" lost Harriet Tubman's answer, "disease" an accurate one about antibodies —
    /// but in a question they signal what the child is reaching for. "poison" and "smoke" are left to
    /// `blockedPhrases`, since "poison ivy" and "why do volcanoes smoke" are fine.
    private static let questionOnlyWords: Set<String> = [
        // war
        "war", "wars", "warring",
        // crime and the legal system
        "arrest", "arrests", "arrested", "arresting",
        "jail", "jailed", "prison", "imprisoned", "imprisonment",
        "convict", "convicts", "convicted", "criminal", "criminals",
        "felony", "felon", "felons", "sentenced", "sentencing",
        // death and suffering
        "died", "dies", "dying", "death", "deaths", "dead",
        "suffer", "suffers", "suffering", "suffered",
        // medical and mental health
        "diagnosis", "diagnoses", "diagnosed",
        "disorder", "disorders", "dwarfism",
        "depression", "depressed", "anxiety", "anxious",
        "therapy", "therapies", "therapist", "therapists",
        "medication", "medications", "medicated",
        "disease", "diseases", "syndrome", "syndromes",
        "trauma", "traumatized",
        "psychiatrist", "psychiatrists", "psychologist", "psychologists",
        "autism", "autistic", "adhd", "bipolar", "schizophrenia", "ptsd", "ocd",
        "prescription", "prescriptions", "prescribed"
    ]

    private static let blockedWords = graphicWords.union(questionOnlyWords)

    /// Matched at word boundaries (see `containsPhrase`), in questions, passages and answers.
    private static let blockedPhrases: [String] = [
        "self harm", "self-harm", "hurt myself", "hurt someone", "how to hurt",
        // "die" alone is history ("how did George Washington die"); about the child it is not.
        "i die", "want to die", "how to die",
        "make poison", "make a poison", "how to poison", "poison someone", "poison a person", "poison my",
        "poison myself",
        "smoking weed",
        // named battles, without listing every one
        "battle of",
        // personal information
        "your name", "your address", "your home address", "where do you live",
        "phone number", "your email", "your school name", "what school do you go to",
        "your last name", "your social security", "credit card number", "your password",
        // self-judgment and parasocial framing
        "am i", "do you think i am", "do i look", "should i",
        "can you keep a secret", "are you my friend", "will you be my friend",
        "do you love me", "can we be friends", "are you alive", "do you have feelings"
    ]

    /// Openers that don't introduce a topic of their own, so a question starting with one right after
    /// a blocked question stays blocked ("Why isn't it for kids?").
    private static let followUpReferencePhrases: [String] = [
        "why not", "why isn't", "why aren't", "why doesn't", "why don't",
        "why can't", "why won't", "why wouldn't", "why shouldn't", "why would", "why should",
        "what about", "and what about",
        "so why", "so what", "so is it", "so does it", "so then",
        "does it", "do they", "why do they", "why does it", "why did", "why do we",
        "is that why", "does that", "is it",
        "and why", "but why", "then why", "then what", "how come", "how so",
        "why though", "what if", "and does it", "but does it", "why can they"
    ]

    /// The gate on the child's question.
    func evaluate(_ text: String) -> SafetyVerdict {
        contains(Self.blockedWords, in: text) ? .blocked : .allowed
    }

    /// The gate on a generated answer: an answer is Wikipedia's material retold, so only
    /// `graphicWords` apply. Inventions still tend to trip it ("killed in a duel with John Adams").
    func evaluateAnswer(_ answer: String) -> SafetyVerdict {
        contains(Self.graphicWords, in: answer) ? .blocked : .allowed
    }

    /// The passage, or nil when it is unsafe. The whole passage is rejected rather than the offending
    /// sentences dropped, because what is left can still tell the same story in other words.
    func safePassage(_ passage: String) -> String? {
        contains(Self.graphicWords, in: passage) ? nil : passage
    }

    func isBareFollowUp(_ question: String) -> Bool {
        let normalized = question.lowercased()
        return Self.followUpReferencePhrases.contains { normalized.hasPrefix($0) }
    }

    private func contains(_ words: Set<String>, in text: String) -> Bool {
        let normalized = text.lowercased()
        if Self.blockedPhrases.contains(where: { containsPhrase($0, in: normalized) }) { return true }
        return normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .contains { words.contains($0) }
    }

    /// Whether `phrase` occurs in `text` starting at a word boundary. Its final word may run on
    /// ("self harm" catches "self harming") unless it is two letters or fewer, because short words
    /// run on into unrelated ones ("am i" → "am interested"). Plain substring matching fired "am i"
    /// inside "team is".
    private func containsPhrase(_ phrase: String, in text: String) -> Bool {
        let finalWordIsShort = (phrase.split(separator: " ").last?.count ?? 0) <= 2
        var searchStart = text.startIndex
        while let match = text.range(of: phrase, range: searchStart..<text.endIndex) {
            let startsAtBoundary = match.lowerBound == text.startIndex
                || !isWordCharacter(text[text.index(before: match.lowerBound)])
            let endsAtBoundary = match.upperBound == text.endIndex
                || !isWordCharacter(text[match.upperBound])
            if startsAtBoundary && (endsAtBoundary || !finalWordIsShort) {
                return true
            }
            searchStart = text.index(after: match.lowerBound)
        }
        return false
    }

    private func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
