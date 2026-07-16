//
//  LaunchScreenView.swift
//  WonderBug
//

import SwiftUI

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
