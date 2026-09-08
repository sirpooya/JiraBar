import SwiftUI
import WebKit

/// Renders `renderedFields.description`, which Jira returns as HTML because the source is wiki
/// markup rather than Markdown or ADF.
///
/// A WKWebView rather than an HTML-to-AttributedString pass: wiki markup produces tables, panels,
/// code blocks and nested lists, and NSAttributedString's HTML importer drops or mangles most of
/// that. The cost is one web view per detail view, which is acceptable for one popover.
///
/// The page is inert. Nothing may navigate; a clicked link opens in the user's browser instead.
/// A web view that refuses to scroll itself, handing the wheel to whatever contains it.
///
/// Height is measured from the page, so in theory the frame always fits the content and there is
/// nothing to scroll. In practice a measurement can land a few points short while a font or an
/// image is still settling, and WKWebView answers that by scrolling internally: the thread slides
/// under the composer while the detail view's own scroller sits untouched. Forwarding the event
/// makes that impossible rather than unlikely.
final class NonScrollingWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

struct DescriptionWebView: NSViewRepresentable {
    let html: String
    let isDark: Bool
    /// Effectively uncapped by default. A capped web view scrolls inside itself, which put a
    /// second scroll area inside the one the detail view already has: two nested scrollers, and
    /// the trackpad picking whichever one it felt like. The page is sized to its full content and
    /// the detail view's own ScrollView is the only thing that scrolls.
    var maxHeight: CGFloat = 20000
    /// Called with the comment id when an Edit link in the rendered thread is clicked.
    var onEditComment: ((String) -> Void)?
    /// Called with (comment id, emoji codepoint) to toggle a reaction.
    var onToggleReaction: ((String, String) -> Void)?
    /// Called with the comment id when the reaction picker is asked for.
    var onPickReaction: ((String) -> Void)?
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: Self.heightChannel)
        let webView = NonScrollingWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: heightChannel)
    }

    /// The name the page posts its height on.
    static let heightChannel = "height"

    func updateNSView(_ webView: WKWebView, context: Context) {
        let document = Self.document(body: html, isDark: isDark)
        guard context.coordinator.lastLoaded != document else { return }
        context.coordinator.lastLoaded = document
        webView.loadHTMLString(document, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let parent: DescriptionWebView
        var lastLoaded: String?

        init(_ parent: DescriptionWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.body.scrollHeight") { value, _ in
                guard let height = value as? CGFloat else { return }
                self.apply(height)
            }
        }

        /// The page reports its own height whenever it changes, so a late web font, an image that
        /// finishes loading or a reaction chip wrapping onto a second line all resize the frame.
        /// The load-time reading alone was a snapshot of a page that had not finished laying out.
        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == DescriptionWebView.heightChannel,
                  let height = message.body as? NSNumber else { return }
            apply(CGFloat(height.doubleValue))
        }

        private func apply(_ height: CGFloat) {
            DispatchQueue.main.async {
                let fitted = min(max(height, 20), self.parent.maxHeight)
                guard abs(self.parent.contentHeight - fitted) > 0.5 else { return }
                self.parent.contentHeight = fitted
            }
        }

        /// The only navigation allowed is the initial load. Everything else leaves for the browser.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .other, navigationAction.request.url == nil
                || navigationAction.request.url?.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated {
                if url.scheme == JiraComment.actionScheme {
                    // In-document controls, not links. They never leave the app.
                    let parts = url.pathComponents.filter { $0 != "/" }
                    DispatchQueue.main.async {
                        switch url.host {
                        case "edit":
                            if let id = parts.first { self.parent.onEditComment?(id) }
                        case "picker":
                            if let id = parts.first { self.parent.onPickReaction?(id) }
                        case "react":
                            if parts.count >= 2 {
                                self.parent.onToggleReaction?(parts[0], parts[1])
                            }
                        default:
                            break
                        }
                    }
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
            decisionHandler(.cancel)
        }
    }

    /// The stylesheet is inlined rather than injected after load, so the first paint is already
    /// the right colors and the popover does not flash white in dark mode.
    static func document(body: String, isDark: Bool) -> String {
        let text = isDark ? "#e8e8ea" : "#1d1d1f"
        let muted = isDark ? "#a0a0a6" : "#6b6b70"
        let rule = isDark ? "rgba(255,255,255,0.14)" : "rgba(0,0,0,0.12)"
        let surface = isDark ? "rgba(255,255,255,0.06)" : "rgba(0,0,0,0.04)"
        let link = isDark ? "#4da3ff" : "#0a66c2"

        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: \(isDark ? "dark" : "light"); }
          html, body { margin: 0; padding: 0; background: transparent; }
          body {
            font: 12.5px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            color: \(text);
            word-wrap: break-word;
            overflow-x: hidden;
          }
          p { margin: 0 0 8px; }
          p:last-child { margin-bottom: 0; }
          h1, h2, h3, h4 { font-size: 13px; font-weight: 600; margin: 12px 0 6px; }
          h1:first-child, h2:first-child, h3:first-child, p:first-child { margin-top: 0; }
          ul, ol { margin: 0 0 8px; padding-left: 18px; }
          li { margin: 2px 0; }
          a { color: \(link); text-decoration: none; }
          a:hover { text-decoration: underline; }
          code, tt { font: 11px/1.4 ui-monospace, "SF Mono", Menlo, monospace;
                     background: \(surface); padding: 1px 4px; border-radius: 3px; }
          pre { background: \(surface); padding: 8px 10px; border-radius: 6px;
                overflow-x: auto; margin: 0 0 8px; }
          pre code { background: none; padding: 0; }
          blockquote { margin: 0 0 8px; padding-left: 10px; border-left: 2px solid \(rule);
                       color: \(muted); }
          table { border-collapse: collapse; width: 100%; margin: 0 0 8px; display: block;
                  overflow-x: auto; }
          th, td { border: 1px solid \(rule); padding: 4px 7px; text-align: left; font-size: 12px; }
          th { background: \(surface); font-weight: 600; }
          img { max-width: 100%; height: auto; border-radius: 4px; }
          hr { border: none; border-top: 1px solid \(rule); margin: 10px 0; }
          .panel, .panelContent { background: \(surface); border-radius: 6px; padding: 8px 10px;
                                  margin: 0 0 8px; }
          /* One comment. The rule above each one separates the thread without boxing every
             entry, which at this width would be all border and no text. */
          .jc { padding: 8px 0; border-top: 1px solid \(rule); }
          .jc:first-child { border-top: none; padding-top: 0; }
          .jc:last-child { padding-bottom: 0; }
          .jcm { color: \(muted); font-size: 11px; margin-bottom: 3px; }
          /* Comment bodies carry whatever inline sizes the Jira editor left in them, so one
             comment can render at twice the size of the one above it. Size and line height are
             normalised with !important, because those sizes are inline styles and nothing else
             overrides them. Weight, style, colour, lists, tables and links are untouched: a bold
             run stays bold, a heading stays a heading, it just stops being huge. */
          .jc p, .jc li, .jc div, .jc span, .jc td, .jc th, .jc blockquote, .jc font,
          .jc h1, .jc h2, .jc h3, .jc h4, .jc h5, .jc h6 {
            font-size: 12.5px !important;
            line-height: 1.5 !important;
          }
          .jc code, .jc tt, .jc pre, .jc pre * { font-size: 11px !important; }
          /* Higher specificity than the rules above, so the byline and the action row keep their
             own smaller size. */
          .jc .jcm, .jc .jce, .jc .jce a { font-size: 11px !important; }
          /* Edit only. There is no delete control here by design. */
          .jce { margin-top: 5px; display: flex; align-items: center; gap: 4px; flex-wrap: wrap; }
          .jcl { font-size: 11px; color: \(muted); margin-left: 4px; }
          .jcl:hover { color: \(link); text-decoration: underline; }
          /* Reaction chips. The one you added yourself is outlined in the accent colour. */
          .jr, .jrp { font-size: 11px; line-height: 1; color: \(text); background: \(surface);
                      border: 1px solid transparent; border-radius: 10px; padding: 3px 7px;
                      text-decoration: none; }
          .jr:hover, .jrp:hover { background: \(rule); text-decoration: none; }
          .jrm { border-color: \(link); color: \(link); }
          .jrp { color: \(muted); display: inline-flex; align-items: center; padding: 3px 6px; }
          .jrpi { width: 13px; height: 13px; display: block; }
          /* A comment body inherits the direction its own text resolves to, so the paragraph
             margins and list indents flip with it rather than staying on the left. */
          .jcb[dir="auto"] { unicode-bidi: plaintext; }
        </style></head>
        <body dir="auto">\(body)</body>
        <script>
          (function () {
            var channel = window.webkit && window.webkit.messageHandlers
                          && window.webkit.messageHandlers.\(heightChannel);
            if (!channel) { return; }
            var last = -1;
            function report() {
              var height = Math.ceil(document.body.scrollHeight);
              if (height === last) { return; }
              last = height;
              channel.postMessage(height);
            }
            if (window.ResizeObserver) {
              new ResizeObserver(report).observe(document.body);
            }
            window.addEventListener('load', report);
            report();
          })();
        </script></html>
        """
    }
}
