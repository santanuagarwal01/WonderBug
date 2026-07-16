//
//  WonderBugApp.swift
//  WonderBug
//
//  Created by Santanu Agarwal on 14/06/26.
//

import SwiftUI
import SwiftData

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
