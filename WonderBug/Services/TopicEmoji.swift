//
//  TopicEmoji.swift
//  WonderBug
//

import Foundation

/// Chooses the one emoji shown after an answer, from a fixed list. The model used to pick its own
/// and was often wrong (a peacock for spiders, an elephant for a giraffe); a list is either right
/// or shows nothing.
enum TopicEmoji {

    /// Checks the Wikipedia article's title first, then the question, and returns the emoji for the
    /// first listed word; nil when nothing matches. The title comes first so "Is a whale a fish?"
    /// gets the whale, not the fish.
    static func emoji(title: String?, question: String) -> String? {
        for text in [title, question].compactMap({ $0 }) {
            for word in WikiSearchService.words(in: text) {
                if let emoji = byKeyword[word] ?? byKeyword[WikiSearchService.stem(word)] {
                    return emoji
                }
            }
        }
        return nil
    }

    private static let byKeyword: [String: String] = [
        // animals
        "koala": "🐨", "spider": "🕷️", "whale": "🐋", "shark": "🦈", "frog": "🐸", "bee": "🐝",
        "cat": "🐱", "dog": "🐶", "owl": "🦉", "penguin": "🐧", "elephant": "🐘", "giraffe": "🦒",
        "zebra": "🦓", "octopus": "🐙", "snake": "🐍", "bat": "🦇", "fish": "🐟", "bird": "🐦",
        "dinosaur": "🦕", "butterfly": "🦋", "caterpillar": "🐛", "ant": "🐜", "lion": "🦁",
        "tiger": "🐯", "monkey": "🐒", "horse": "🐴", "cow": "🐄", "pig": "🐷", "rabbit": "🐰",
        "turtle": "🐢", "crab": "🦀", "dolphin": "🐬", "ostrich": "🐦",
        // space
        "planet": "🪐", "jupiter": "🪐", "saturn": "🪐", "mercury": "🪐", "mars": "🪐", "pluto": "🪐",
        "sun": "☀️", "moon": "🌙", "star": "⭐", "earth": "🌍", "galaxy": "🌌", "rocket": "🚀",
        // weather and nature
        "volcano": "🌋", "thunder": "⛈️", "lightning": "⚡", "rain": "🌧️", "rainbow": "🌈",
        "snow": "❄️", "cloud": "☁️", "sky": "☁️", "tree": "🌳", "flower": "🌸", "leaf": "🍃",
        "leaves": "🍃", "grass": "🌱", "plant": "🌱", "ivy": "🌿", "ocean": "🌊", "sea": "🌊",
        "water": "💧", "mountain": "🏔️", "ice": "🧊",
        // body
        "heart": "❤️", "bone": "🦴", "tooth": "🦷", "teeth": "🦷", "brain": "🧠", "sleep": "😴",
        // things
        "titanic": "🚢", "ship": "🚢", "airplane": "✈️", "car": "🚗", "train": "🚆", "bulb": "💡",
        "honey": "🍯", "tomato": "🍅", "apple": "🍎", "book": "📚",
    ]
}
