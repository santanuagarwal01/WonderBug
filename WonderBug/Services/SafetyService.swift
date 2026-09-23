//
//  SafetyService.swift
//  WonderBug
//

import Foundation

/// Outcome of the safety check: a blocked question never reaches the answer model, a blocked
/// answer is never shown, and both are replaced by the fixed `SafetyService.blockedResponse` string.
enum SafetyVerdict: Equatable {
    case allowed
    case blocked
}

/// Contract the view model checks text against — each question before an answer is generated,
/// and each generated answer before it is shown.
protocol SafetyServicing {
    func evaluate(_ text: String) -> SafetyVerdict
    func isBareFollowUp(_ question: String) -> Bool
    func safePassage(_ passage: String) -> String?
}

/// Rule-based content gate, independent of whichever model answers the question.
/// Every blocked question or answer gets the exact same response, with zero variation and no
/// explanation — this list is deliberately conservative and should be extended, never loosened.
struct SafetyService: SafetyServicing {

    static let blockedResponse = "I'm not sure about that — let's ask your grown-up!"

    /// Single words, matched against whole tokens only (never as a substring) so that e.g. "war"
    /// doesn't trip on "warm"/"software"/"forward" and "kill" doesn't trip on "skill". Includes the
    /// obvious inflected forms of each word so switching off substring matching doesn't quietly lose
    /// coverage of plurals/tenses the old check used to catch incidentally.
    ///
    /// Deliberately excludes "poison" and "smoke" as bare words — both have overwhelmingly common,
    /// benign meanings for this age group ("poison ivy", "poison dart frog", "why do volcanoes
    /// smoke"; the product spec itself lists "poison ivy" as a required example question) — the
    /// actually-dangerous intent behind those words is caught instead by the phrases below.
    private let blockedWords: Set<String> = [
        // violence, weapons, war
        "gun", "guns", "knife", "knives", "weapon", "weapons",
        "kill", "kills", "killing", "killed", "killer", "killers",
        "murder", "murders", "murdering", "murdered", "murderer", "murderers",
        "assault", "assaults", "assaulted",
        "war", "wars", "warring",
        "bomb", "bombs", "bombing",
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
        // crime / legal system — also closes off the follow-up chain when a factual answer about
        // a person (real or model-hallucinated) veers into "what crime did they commit"
        "arrest", "arrests", "arrested", "arresting",
        "jail", "jailed", "prison", "imprisoned", "imprisonment",
        "convict", "convicts", "convicted", "criminal", "criminals",
        "felony", "felon", "felons", "sentenced", "sentencing",
        // sexual topics
        "sex", "porn", "pornography", "pornographic", "sexual", "naked", "nude", "nudity",
        "orgasm", "orgasms", "masturbate", "masturbation", "intercourse", "erotic", "fetish",
        "prostitute", "prostitution", "stripper", "strippers", "hooker", "hookers",
        "rape", "raped", "molest", "molested", "molesting",
        // abuse
        "abuse", "abused", "abusing", "abuser",
        // death / suffering detail
        "died", "dies", "dying", "death", "deaths", "dead", "corpse", "corpses",
        "cadaver", "cadavers", "suffer", "suffers", "suffering", "suffered",
        "decapitate", "decapitated", "decapitation",
        "mutilate", "mutilated", "mutilation",
        "gore", "gory", "autopsy", "autopsies",
        // dangerous instructions
        "explosive", "explosives",
        // adult / teen substances
        "alcohol", "beer", "wine", "whiskey", "vodka", "rum", "tequila", "liquor",
        "drunk", "drunken", "intoxicated",
        "drug", "drugs", "marijuana", "cannabis", "cocaine", "heroin", "meth", "methamphetamine",
        "opioid", "opioids", "nicotine", "tobacco",
        "cigarette", "cigarettes", "cigar", "cigars",
        "vape", "vapes", "vaping",
        "overdose", "overdosed", "addiction", "addicted", "addict", "addicts",
        // medical / mental health / diagnostic language
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

    /// Multi-word phrases, matched at word boundaries (see `containsPhrase`). Plain substring
    /// matching looked safe but wasn't: "am i" fired inside "team is", "dam in" and "program is"
    /// (thousands of times across Wikipedia text), blocking questions like "Which team is the best?".
    private let blockedPhrases: [String] = [
        "self harm", "self-harm", "hurt myself", "hurt someone", "how to hurt",
        // dangerous instructions involving otherwise-benign words (see blockedWords comment above)
        "make poison", "make a poison", "how to poison", "poison someone", "poison a person", "poison my",
        // "poison my" no longer runs on into "myself" (its final word is short — see containsPhrase)
        "poison myself",
        "make a bomb", "build a bomb", "make a weapon", "make a gun", "build a gun",
        "smoking cigarettes", "smoke a cigarette", "smoking weed",
        // named historical battles/wars — generic pattern rather than an unlistable set of
        // specific battle names ("battle of shiloh", "battle of hastings", etc.)
        "battle of",
        // personal information requests
        "your name", "what is your name", "what's your name",
        "your address", "your home address", "where do you live",
        "phone number", "your phone number",
        "your email", "your email address",
        "your school name", "what school do you go to",
        "your last name", "your social security", "credit card number", "your password",
        // self-judgment, personal identity, parasocial framing
        "am i", "do you think i am", "who am i", "why am i",
        "am i pretty", "am i ugly", "am i fat", "am i stupid", "am i smart", "do i look",
        "should i", "what should i do",
        "can you keep a secret", "are you my friend", "will you be my friend",
        "do you love me", "can we be friends", "are you alive", "do you have feelings"
    ]

    /// Short, reference-heavy openers that don't introduce a topic of their own — used to keep a
    /// pending blocked topic blocked across an immediate follow-up ("Why isn't it for kids?"),
    /// without ever re-blocking a later question just because *something* was blocked earlier.
    private let followUpReferencePhrases: [String] = [
        "why not", "why isn't", "why aren't", "why doesn't", "why don't",
        "why can't", "why won't", "why wouldn't", "why shouldn't", "why would", "why should",
        "what about", "so what about", "and what about",
        "so why", "so what", "so is it", "so does it", "so then",
        "does it", "do they", "why do they", "why does it", "why did", "why do we",
        "is that why", "is it because", "does that mean", "does that", "is it",
        "and why", "but why", "then why", "then what", "how come", "how so",
        "why though", "what if", "and does it", "but does it", "why can they"
    ]

    /// Checks text — a question, or a generated answer — against the phrase list (word-boundary
    /// match) and word list (whole-token match), and returns whether it is safe for a child.
    func evaluate(_ text: String) -> SafetyVerdict {
        let normalized = text.lowercased()

        if blockedPhrases.contains(where: { containsPhrase($0, in: normalized) }) {
            return .blocked
        }

        let words = normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        let isBlocked = words.contains { blockedWords.contains($0) }
        return isBlocked ? .blocked : .allowed
    }

    /// A Wikipedia passage to answer from, or nil when it is unsafe for a child — in which case the
    /// app answers "I don't know yet" without running the model at all.
    ///
    /// The app ships all of Simple English Wikipedia, which is not written for 4-8 year olds: one in
    /// five article openings contains a blocked word. The whole passage is rejected rather than the
    /// offending sentences dropped, because the sentences left behind can still carry the same story
    /// in words this list does not cover: trimming the James Earl Ray passage removes "convicted of
    /// murdering" but keeps "he had shot King". Measured over the test questions, whole-passage
    /// rejection costs 2 of 66 passages.
    func safePassage(_ passage: String) -> String? {
        evaluate(passage) == .allowed ? passage : nil
    }

    /// True when the question opens with a reference phrase ("Why not", "What about"...) —
    /// the view model uses this to keep a just-blocked topic blocked across such follow-ups.
    func isBareFollowUp(_ question: String) -> Bool {
        let normalized = question.lowercased()
        return followUpReferencePhrases.contains { normalized.hasPrefix($0) }
    }

    /// Whether `phrase` occurs in `text` starting at a word boundary. Its final word may run on into
    /// a longer word, so "self harm" still catches "self harming" and "make poison" catches "make
    /// poisonous" — except when that final word is two letters or fewer, because short words run on
    /// into unrelated ones ("am i" → "am interested", "battle of" → "battle often").
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
