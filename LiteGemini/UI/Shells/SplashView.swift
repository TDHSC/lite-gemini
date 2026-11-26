//
//  SplashView.swift
//  LiteGemini
//
//  Created by Jray on 2026/2/14.
//

import SwiftUI

/// Minimalist monochrome splash screen displayed during initial page load.
/// Uses a restrained geometric mark with a calm breathing pulse on the exact Gemini surface color.
struct SplashView: View {

    /// Whether the content is still loading
    var isLoading: Bool

    /// Surface color synced with the Gemini page backdrop
    var backgroundColor: Color = Color(nsColor: AppDelegate.geminiSurfaceNSColor)

    /// Controls the fade-out transition when loading completes
    @State private var isVisible: Bool = true

    /// Drives the calm breathing pulse animation
    @State private var isBreathing: Bool = false

    // MARK: - Body

    var body: some View {
        ZStack {
            backgroundColor
                .ignoresSafeArea()

            ZStack {
                // Subtle outer hairline halo
                Circle()
                    .strokeBorder(
                        Color.primary.opacity(isBreathing ? 0.12 : 0.04),
                        lineWidth: 1
                    )
                    .frame(width: 56, height: 56)
                    .scaleEffect(isBreathing ? 1.06 : 0.94)

                // Crisp monochrome four-point geometric star mark
                MonochromeSparkShape()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(0.88),
                                Color.primary.opacity(0.42)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 24, height: 24)
                    .opacity(isBreathing ? 0.85 : 0.30)
                    .scaleEffect(isBreathing ? 1.02 : 0.94)
            }
        }
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.98)
        .onChange(of: isLoading) { _, newValue in
            if !newValue {
                withAnimation(.easeOut(duration: 0.35)) {
                    isVisible = false
                }
            }
        }
        .allowsHitTesting(isVisible)
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.6)
                .repeatForever(autoreverses: true)
            ) {
                isBreathing = true
            }
        }
    }
}

#Preview {
    SplashView(isLoading: true)
        .frame(width: 800, height: 600)
}
