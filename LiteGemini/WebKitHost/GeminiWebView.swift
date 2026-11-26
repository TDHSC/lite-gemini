import SwiftUI
import WebKit

struct GeminiWebView: NSViewRepresentable {
    @ObservedObject var viewModel: ClassicWebViewModel

    func makeNSView(context: Context) -> WKWebView {
        return viewModel.webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        // No updates needed here
    }
}
