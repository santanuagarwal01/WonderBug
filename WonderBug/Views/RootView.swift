//
//  RootView.swift
//  WonderBug
//

import SwiftUI

/// First view on screen: shows the SwiftUI splash (`LaunchScreenView`) for 2 seconds, then
/// cross-fades into the real app (`MainTabView`).
struct RootView: View {

    @State private var showLaunchScreen = true

    var body: some View {
        Group {
            if showLaunchScreen {
                LaunchScreenView()
                    .transition(.opacity)
            } else {
                MainTabView()
                    .transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.4)) {
                showLaunchScreen = false
            }
        }
    }
}
