//
//  WonderBugApp.swift
//  WonderBug
//
//  Created by Santanu Agarwal on 14/06/26.
//

import SwiftUI
import SwiftData

/// Hosts the UI in one NavigationStack and creates the SwiftData container for `HistoryItem`.
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
