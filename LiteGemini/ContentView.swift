//
//  ContentView.swift
//  LiteGemini
//
//  Created by Jray on 2026/2/10.
//

import SwiftUI
import AppKit

/// Native NSView that enables dragging the window from the seamless top titlebar band
/// and supports standard macOS double-click to zoom.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggableTitleBarView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableTitleBarView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseUp(with event: NSEvent) {
            super.mouseUp(with: event)
            if event.clickCount == 2 {
                window?.performZoom(nil)
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var viewModel: WebViewModel

    /// Tracks whether the initial page load has completed
    @State private var hasFinishedInitialLoad: Bool = false

    /// Hover state for the monochrome reload button
    @State private var isHoveringReload: Bool = false

    private static let titleBarHeight: CGFloat = 28

    var body: some View {
        ZStack(alignment: .top) {
            // Seamless backdrop matching the Gemini web page surface color
            viewModel.pageBackgroundColor
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Seamless 28pt top bar that blends with Gemini's background and hosts traffic lights
                WindowDragArea()
                    .frame(height: Self.titleBarHeight)
                    .frame(maxWidth: .infinity)
                    .background(viewModel.pageBackgroundColor)

                GeminiWebView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea(.container, edges: .top)
            .frame(minWidth: 800, minHeight: 600)

            // Minimalist monochrome splash screen for initial load (no error)
            if !hasFinishedInitialLoad && viewModel.errorMessage == nil {
                SplashView(
                    isLoading: !viewModel.isPageReady,
                    backgroundColor: viewModel.pageBackgroundColor
                )
                .ignoresSafeArea()
                .zIndex(1)
            }

            // Ultra-subtle monochrome top hairline indicator for subsequent navigations
            if hasFinishedInitialLoad && viewModel.isLoading && viewModel.errorMessage == nil {
                MonochromeTopLoadingBar()
                    .padding(.top, Self.titleBarHeight)
                    .ignoresSafeArea(.container, edges: .top)
                    .transition(.opacity)
            }

            // Minimalist monochrome error state
            if let errorMessage = viewModel.errorMessage {
                ZStack {
                    viewModel.pageBackgroundColor
                        .ignoresSafeArea()

                    VStack(spacing: 18) {
                        ZStack {
                            Circle()
                                .fill(Color.primary.opacity(0.05))
                                .frame(width: 56, height: 56)
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                                )

                            Image(systemName: "wifi.exclamationmark")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(Color.primary.opacity(0.65))
                        }

                        Text(errorMessage)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Color.primary.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)

                        Button {
                            viewModel.retry()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .medium))
                                Text("Reload")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(Color.primary.opacity(0.85))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(Color.primary.opacity(isHoveringReload ? 0.12 : 0.07))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.primary.opacity(isHoveringReload ? 0.24 : 0.14), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isHoveringReload = hovering
                            }
                        }
                        .padding(.top, 2)
                    }
                    .padding(32)
                }
                .zIndex(1.5)
            }

            // Monochrome floating capsule notice for downloads
            if let notice = viewModel.downloadNotice {
                HStack(spacing: 10) {
                    Image(systemName: notice.isError
                          ? "exclamationmark.circle"
                          : "arrow.down.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(notice.isError ? Color.orange.opacity(0.9) : Color.primary.opacity(0.75))

                    Text(notice.message)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.88))
                        .lineLimit(1)

                    if let fileURL = notice.fileURL {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.9))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.primary.opacity(0.1))
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
                .padding(.top, Self.titleBarHeight + 8)
                .ignoresSafeArea(.container, edges: .top)
                .task(id: notice.id) {
                    // Auto-dismiss after 4 s; .task(id:) cancels this when a newer notice replaces it
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled else { return }
                    if viewModel.downloadNotice?.id == notice.id {
                        viewModel.downloadNotice = nil
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.downloadNotice?.id)
        .onChange(of: viewModel.isPageReady) { _, newValue in
            // Mark initial load as complete once the input field is detected
            if newValue && !hasFinishedInitialLoad && viewModel.errorMessage == nil {
                // Delay slightly to allow the SplashView fade-out animation to play
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    hasFinishedInitialLoad = true
                }
            }
        }
    }
}

/// Subtle 1.5pt monochrome indeterminate bar for subsequent page loads
private struct MonochromeTopLoadingBar: View {
    @State private var phase: CGFloat = -0.35

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.05))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(0.0),
                                Color.primary.opacity(0.32),
                                Color.primary.opacity(0.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(geo.size.width * 0.35, 120), height: 1.5)
                    .offset(x: phase * geo.size.width)
            }
        }
        .frame(height: 1.5)
        .clipped()
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                phase = 0.65
            }
        }
    }
}

#Preview {
    ContentView(viewModel: WebViewModel())
}
