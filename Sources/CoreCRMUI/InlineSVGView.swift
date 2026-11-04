import CoreKit
import SwiftUI
import WebKit

/// Renders inline SVG markup (from a CMS `svg` field) in a lightweight,
/// transparent web view. SwiftUI/UIImage can't parse SVG and the project is
/// zero-dependency, so a small WKWebView is the simplest native path. Kept to
/// detail views — not list rows — so there's at most a handful on screen.
struct InlineSVGView {
  let svg: String

  private func makeWebView() -> WKWebView {
    let webView = WKWebView()
    #if os(iOS)
      webView.isOpaque = false
      webView.backgroundColor = .clear
      webView.scrollView.isScrollEnabled = false
      webView.scrollView.backgroundColor = .clear
    #else
      webView.setValue(false, forKey: "drawsBackground")
    #endif
    return webView
  }

  private func load(into webView: WKWebView) {
    let html = """
      <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">\
      <style>html,body{margin:0;padding:0;height:100%;background:transparent}\
      body{display:flex;align-items:center;justify-content:center}\
      svg{max-width:100%;max-height:100%;height:auto;width:auto}</style></head>\
      <body>\(svg)</body></html>
      """
    webView.loadHTMLString(html, baseURL: nil)
  }
}

#if os(iOS)
  extension InlineSVGView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView() }
    func updateUIView(_ webView: WKWebView, context: Context) { load(into: webView) }
  }
#else
  extension InlineSVGView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ webView: WKWebView, context: Context) { load(into: webView) }
  }
#endif
