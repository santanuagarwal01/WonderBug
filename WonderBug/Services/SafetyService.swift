//
//  SafetyService.swift
//  WonderBug
//

import Foundation

enum SafetyVerdict: Equatable {
    case allowed
    case blocked
}

protocol SafetyServicing {
    func evaluate(_ question: String) -> SafetyVerdict
    func isBareFollowUp(_ question: String) -> Bool
}

/// Rule-based content gate, independent of whichever model answers the question.
/// Every blocked question gets the exact same response, with zero variation and no explanation —
/// this list is deliberately conservative and should be extended, never loosened.
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
        "kill", "kills", "killing", "killed",
        "murder", "murders", "murdering", "murdered",
        "war", "wars", "warring",
        "bomb", "bombs", "bombing",
        "shoot", "shooting", "shootings", "shooter", "shooters",
        "stab", "stabs", "stabbing", "stabbed",
        "torture", "tortures", "torturing", "tortured",
        "assassinate", "assassinated", "assassination",
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

    /// Multi-word phrases, matched as substrings — safe unlike single words, since it's practically
    /// impossible for one of these to appear accidentally inside an unrelated longer word.
    private let blockedPhrases: [String] = [
        "self harm", "self-harm", "hurt myself", "hurt someone", "how to hurt",
        // dangerous instructions involving otherwise-benign words (see blockedWords comment above)
        "make poison", "make a poison", "how to poison", "poison someone", "poison a person", "poison my",
        "make a bomb", "build a bomb", "make a weapon", "make a gun", "build a gun",
        "smoking cigarettes", "smoke a cigarette", "smoking weed",
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

    func evaluate(_ question: String) -> SafetyVerdict {
        let normalized = question.lowercased()

        if blockedPhrases.contains(where: { normalized.contains($0) }) {
            return .blocked
        }

        let words = normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        let isBlocked = words.contains { blockedWords.contains($0) }
        return isBlocked ? .blocked : .allowed
    }

    func isBareFollowUp(_ question: String) -> Bool {
        let normalized = question.lowercased()
        return followUpReferencePhrases.contains { normalized.hasPrefix($0) }
    }
}
