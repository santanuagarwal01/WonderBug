//
//  LaunchScreenView.swift
//  WonderBug
//

import SwiftUI

/// Splash screen: brand background with the full logo+wordmark at 80% of screen width,
/// so it scales consistently across device sizes.
struct LaunchScreenView: View {
    var body: some View {
        ZStack {
            Color.wbBackground
                .ignoresSafeArea()

            Image("logo+wordmark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .containerRelativeFrame(.horizontal) { width, _ in
                    width * 0.8
                }
        }
    }
}

#Preview {
    LaunchScreenView()
}
