//
//  DebugLog.swift
//  WonderBug
//

import Foundation

/// Prints each step of the ask flow — the search result, the passage, the exact prompt, and the
/// model's raw and cleaned output — to Xcode's console, so a device run can be checked step by step
/// rather than only by the final answer on screen.
///
/// Uses `print` rather than `os.Logger` because the unified log truncates long messages, and the
/// prompts here run to a couple of thousand characters. Compiled out of release builds, so a
/// child's questions never reach the device log in the shipped app.
enum DebugLog {

    /// Marks the start of one question, so separate questions are easy to find in the console.
    static func question(_ text: String) {
        #if DEBUG
        print("\n══════════ QUESTION: \(text) ══════════")
        #endif
    }

    /// One labelled step, printed as a header line followed by its full text.
    static func section(_ label: String, _ body: String) {
        #if DEBUG
        print("── \(label) ──\n\(body)")
        #endif
    }
}
