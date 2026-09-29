//
//  TopicEmoji.swift
//  WonderBug
//

import Foundation

/// The one emoji shown after an answer, from a fixed list: the model's own picks were often wrong
/// (a peacock for spiders), and a list is either right or shows nothing.
enum TopicEmoji {

    /// The emoji for the first listed word of the article's title, then of the question, so "Is a
    /// whale a fish?" gets the whale.
    static func emoji(title: String, question: String) -> String? {
        for text in [title, question] {
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
