//
//  WonderBugApp.swift
//  WonderBug
//
//  Created by Santanu Agarwal on 14/06/26.
//

import SwiftUI
import SwiftData

/// App entry point: hosts the whole UI inside one NavigationStack and creates the SwiftData
/// container for `HistoryItem`, which every view reaches through the SwiftUI environment.
@main
struct WonderBugApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                RootView()
                    .preferredColorScheme(.light)
            }
        }
        .modelContainer(for: HistoryItem.self)
    }
}
