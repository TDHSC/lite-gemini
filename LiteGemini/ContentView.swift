//
//  ContentView.swift
//  LiteGemini
//
//  Created by Jray on 2026/2/10.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: WebViewModel

    /// Tracks whether the initial page load has completed
    @State private var hasFinishedInitialLoad: Bool = false

    var body: some View {
        ZStack {
            GeminiWebView(viewModel: viewModel)
                .frame(minWidth: 800, minHeight: 600)

            // Branded splash screen for initial load (no error)
            if !hasFinishedInitialLoad && viewModel.errorMessage == nil {
                SplashView(isLoading: !viewModel.isPageReady)
                    .zIndex(1)
            }

            // Subtle top progress bar for subsequent navigations
            if hasFinishedInitialLoad && viewModel.isLoading && viewModel.errorMessage == nil {
                VStack {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Color(red: 0.35, green: 0.50, blue: 0.98))
                    Spacer()
                }
                .transition(.opacity)
            }

            // Error message and retry
            if let errorMessage = viewModel.errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text(errorMessage)
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Button("Reload") {
                        viewModel.retry()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(30)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
                .cornerRadius(12)
            }

            // Download result notice with "Show in Finder", drawn on top of everything else
            if let notice = viewModel.downloadNotice {
                VStack {
                    HStack(spacing: 10) {
                        Image(systemName: notice.isError
                              ? "exclamationmark.triangle.fill"
                              : "arrow.down.circle.fill")
                            .foregroundColor(notice.isError ? .orange : .green)
                        Text(notice.message)
                            .lineLimit(2)
                        if let fileURL = notice.fileURL {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    .padding(.top, 12)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    hasFinishedInitialLoad = true
                }
            }
        }
    }
}

#Preview {
    ContentView(viewModel: WebViewModel())
}
