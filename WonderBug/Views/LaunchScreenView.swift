//
//  LaunchScreenView.swift
//  WonderBug
//

import SwiftUI

/// Splash screen: the logo and wordmark at 80% of the screen width.
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
