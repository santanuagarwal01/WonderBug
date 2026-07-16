//
//  RootView.swift
//  WonderBug
//

import SwiftUI

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
