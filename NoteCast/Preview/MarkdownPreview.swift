//
//  MarkdownPreview.swift
//  NoteCast
//
//  Swift Markdown rendering and WebKit display.
//

import AppKit
import Markdown
import SwiftUI
import WebKit

enum MarkdownPreviewColorScheme: String, Hashable {
    case light
    case dark

    var colorSchemeContent: String {
        rawValue
    }

    var previewTitle: String {
        switch self {
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }
}

/// Converts Markdown source into a complete HTML document for the preview pane.
///
/// NoteCast uses Swift Markdown rather than a hand-written parser. The package
/// builds a CommonMark tree, `HTMLFormatter` turns that tree into HTML, and
/// this type wraps the body in the app's preview CSS.
enum MarkdownPreviewHTML {
    static func documentHTML(markdown: String, title: String, colorScheme: MarkdownPreviewColorScheme) -> String {
        let renderedBody = HTMLFormatter.format(
            markdown,
            options: [.parseAsides, .parseInlineAttributeClass]
        )
        let bodyHTML = renderedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "<p class=\"empty\">Nothing to preview yet.</p>"
            : renderedBody
        let escapedTitle = escapedHTML(title)
        let escapedColorScheme = escapedHTML(colorScheme.rawValue)
        let colorSchemeContent = colorScheme.colorSchemeContent

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="\(colorSchemeContent)">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: https: file:; media-src data: https: file:; style-src 'unsafe-inline'; font-src data:;">
          <style>
            \(githubMarkdownCSS)
            \(noteCastPreviewCSS)
          </style>
        </head>
        <body>
          <article class="markdown-body" data-theme="\(escapedColorScheme)">
            <header class="notecast-preview-header">
              <h1>\(escapedTitle)</h1>
            </header>
            \(bodyHTML)
          </article>
        </body>
        </html>
        """
    }

    private static func escapedHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Default Markdown preview stylesheet.
    ///
    /// The CSS file is vendored from `github-markdown-css` and copied into the
    /// app bundle as a resource. Keeping it standalone makes future stylesheet
    /// refreshes easy and keeps this Swift file focused on app behavior.
    private static var githubMarkdownCSS: String {
        let stylesheetURL = Bundle.main.url(forResource: "github-markdown", withExtension: "css")
            ?? Bundle.main.url(forResource: "github-markdown", withExtension: "css", subdirectory: "Preview")

        guard let url = stylesheetURL,
              let css = try? String(contentsOf: url, encoding: .utf8) else {
            return """
            .markdown-body {
              color: #1f2328;
              background: #ffffff;
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
              font-size: 16px;
              line-height: 1.5;
            }
            @media (prefers-color-scheme: dark) {
              .markdown-body { color: #f0f6fc; background: transparent; }
            }
            .markdown-body pre, .markdown-body code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
            .markdown-body pre { padding: 16px; overflow: auto; background: rgba(125, 125, 125, 0.14); }
            .markdown-body blockquote { padding-left: 1em; color: #656d76; border-left: 0.25em solid #d0d7de; }
            .markdown-body table { border-collapse: collapse; }
            .markdown-body th, .markdown-body td { padding: 6px 13px; border: 1px solid #d0d7de; }
            """
        }

        return css
    }

    /// App-specific wrapper rules around GitHub's stylesheet.
    ///
    /// Upstream CSS styles Markdown content. These rules only make it fit in
    /// NoteCast's in-app WebView: transparent page, readable line length, and a
    /// lightweight title header.
    private static let noteCastPreviewCSS = """
    :root,
    html,
    body {
      color-scheme: light dark;
      background: transparent !important;
      background-color: transparent !important;
    }

    * {
      box-sizing: border-box;
    }

    body {
      margin: 0;
      padding: 18px;
    }

    .markdown-body {
      min-width: 200px;
      max-width: 78ch;
      margin: 0 auto;
      padding: 20px 6px 32px;
      background: transparent !important;
      background-color: transparent !important;
    }

    .markdown-body[data-theme="light"],
    .markdown-body[data-theme="dark"] {
      --bgColor-default: transparent;
    }

    .markdown-body .notecast-preview-header {
      margin: 0 0 20px;
      padding: 0 0 12px;
      border-bottom: 1px solid var(--borderColor-default);
    }

    .markdown-body .notecast-preview-header h1 {
      margin: 0;
      padding-bottom: 0;
      border-bottom: 0;
    }

    .markdown-body .empty {
      color: var(--fgColor-muted);
      font-style: italic;
    }

    .markdown-body pre,
    .markdown-body img {
      border-radius: 8px;
    }
    """
}

/// In-app WebKit preview for generated Markdown HTML.
///
/// This is an `NSViewRepresentable` because SwiftUI does not provide a native
/// WebView. It lives inside the editor pane and never creates a second window.
struct MarkdownPreviewWebView: NSViewRepresentable {
    let html: String
    let colorScheme: MarkdownPreviewColorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webpagePreferences = WKWebpagePreferences()
        webpagePreferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = webpagePreferences

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.appearance = colorScheme.nsAppearance
        webView.underPageBackgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = false
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.layer?.isOpaque = false
        webView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        clearWebViewBackground(webView)
        configureScrollViewRedraw(in: webView)
        DispatchQueue.main.async {
            clearWebViewBackground(webView)
            configureScrollViewRedraw(in: webView)
        }
        webView.loadHTMLString(html, baseURL: nil)
        context.coordinator.lastHTML = html
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.appearance = colorScheme.nsAppearance
        webView.underPageBackgroundColor = .clear
        clearWebViewBackground(webView)
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func clearWebViewBackground(_ webView: WKWebView) {
        if webView.responds(to: Selector(("setDrawsBackground:"))) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.layer?.isOpaque = false
    }

    private func configureScrollViewRedraw(in view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.isOpaque = false

        if let scrollView = view as? NSScrollView {
            scrollView.drawsBackground = false
            scrollView.backgroundColor = .clear
            scrollView.contentView.copiesOnScroll = false
        }

        if let clipView = view as? NSClipView {
            clipView.drawsBackground = false
            clipView.backgroundColor = .clear
        }

        for subview in view.subviews {
            configureScrollViewRedraw(in: subview)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML = ""

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

#Preview("Markdown Stylesheet - Light") {
    MarkdownPreviewStylesheetPreview(colorScheme: .light)
}

#Preview("Markdown Stylesheet - Dark") {
    MarkdownPreviewStylesheetPreview(colorScheme: .dark)
}

private struct MarkdownPreviewStylesheetPreview: View {
    let colorScheme: MarkdownPreviewColorScheme

    private let sampleMarkdown = """
    # Markdown stylesheet sampler

    This preview exercises the GitHub Markdown CSS that NoteCast uses in the
    reader. It includes emphasis, inline code, links, lists, tables, blockquotes,
    alerts, and code blocks.

    ## Lists

    - Capture quick notes from the menu bar.
    - File notes into folders later.
    - Preview Markdown without leaving the editor.

    | Element | Purpose |
    | --- | --- |
    | Heading | Structure |
    | Code | Exact text |
    | Quote | Context |

    ```swift
    struct NoteSummary: View {
        let title: String
    }
    ```
    """

    var body: some View {
        MarkdownPreviewWebView(
            html: MarkdownPreviewHTML.documentHTML(
                markdown: sampleMarkdown,
                title: "Stylesheet sampler",
                colorScheme: colorScheme
            ),
            colorScheme: colorScheme
        )
        .padding(18)
        .frame(width: 760, height: 820)
        .background(TahoeWindowBackground())
    }
}
