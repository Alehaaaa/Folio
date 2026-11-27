// Standalone macOS WKWebView probe for last-page scroll clamping.
// swiftc -o /tmp/folio-last-page checks/reader-last-page-live.swift -framework AppKit -framework WebKit
// /tmp/folio-last-page "~/Library/Application Support/Folio/Extracted/.../chapter.xhtml"
import AppKit
import WebKit

@MainActor
final class LastPageProbe: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    private var web: WKWebView!
    private var window: NSWindow!
    private var ready = false
    private let cfg: [String: Any] = [
        "mode": "pages", "margin": 56, "fontSize": 28, "font": "'Iowan Old Style', serif",
        "columns": false, "comic": false, "bg": "#F9F6E9", "fg": "#29251D",
        "accent": "#946D12", "justify": false, "bold": false
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.count > 1 else { fatalError("Pass a local EPUB chapter path.") }
        let chapter = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let readerScript = try! String(contentsOfFile: "Core/ReaderScript.swift", encoding: .utf8)
        let start = readerScript.range(of: "#\"\"\"\n")!.upperBound
        let end = readerScript.range(of: "\n\"\"\"#", range: start..<readerScript.endIndex)!.lowerBound
        let controller = WKUserContentController()
        controller.addUserScript(.init(source: String(readerScript[start..<end]), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(self, name: "folio")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 970, height: 720), configuration: configuration)
        web.navigationDelegate = self
        window = NSWindow(contentRect: CGRect(x: -2000, y: -2000, width: 970, height: 720),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        window.orderFront(nil)
        web.loadFileURL(chapter, allowingReadAccessTo: chapter.deletingLastPathComponent().deletingLastPathComponent())
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            if !self.ready { fputs("Timed out waiting for reader\n", stderr); exit(2) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let json = String(data: try! JSONSerialization.data(withJSONObject: cfg), encoding: .utf8)!
        web.evaluateJavaScript("window.requestAnimationFrame=(cb)=>setTimeout(cb,0);folio.apply(\(json),{kind:'end'},42);true") { _, error in
            if let error { fputs("apply error: \(error)\n", stderr); exit(2) }
        }
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["type"] as? String == "ready" else { return }
        ready = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if CommandLine.arguments.contains("--prototype-spacer") {
                // Test only. The production reader must keep this aligned
                // when chapters, fonts, sizes or the viewport change.
                self.web.evaluateJavaScript(#"""
                  (() => {
                    const w=document.documentElement.clientWidth;
                    const n=Math.ceil((document.scrollingElement.scrollWidth - 1)/w);
                    const span=document.createElement('div');
                    span.style.cssText='position:absolute;top:0;left:'+(n*w-1)+'px;width:1px;height:1px;visibility:hidden;pointer-events:none';
                    document.documentElement.appendChild(span);
                    folio.goPage(n-1);
                    return true;
                  })()
                """#) { _, error in
                    if let error { fputs("spacer: \(error)\n", stderr); exit(2) }
                    self.takeSnapshot("final page", turn: -1)
                }
            } else {
                self.takeSnapshot("final page", turn: -1)
            }
        }
    }

    private func takeSnapshot(_ title: String, turn: Int?) {
        let script = #"""
            (() => {
              const s=document.scrollingElement, w=document.documentElement.clientWidth;
              const rects=[];
              const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
              while(walker.nextNode()) {
                const n=walker.currentNode;
                if(!n.nodeValue || !n.nodeValue.trim()) continue;
                const r=document.createRange();
                r.selectNodeContents(n);
                for(const b of r.getClientRects()) {
                  if(b.right>0 && b.left<w && b.bottom>0 && b.top<innerHeight)
                    rects.push({text:n.nodeValue.trim().slice(0,32),left:b.left,right:b.right,top:b.top});
                }
              }
              rects.sort((a,b)=>a.top-b.top || a.left-b.left);
              return {viewport:w,documentWidth:document.documentElement.scrollWidth,scrollWidth:s.scrollWidth,
                scrollLeft:s.scrollLeft,maxScroll:s.scrollWidth-w,expectedPageOffset:folio.page*w,
                page:folio.page,pages:folio.pages,bodyWidth:document.body.scrollWidth,
                firstVisible:rects.slice(0,5)};
            })()
        """#
        web.evaluateJavaScript(script) { result, error in
            if let error { fputs("snapshot: \(error)\n", stderr); exit(2) }
            let values = result as? [String: Any] ?? [:]
            let json = String(data: try! JSONSerialization.data(withJSONObject: values, options: .sortedKeys), encoding: .utf8)!
            print("\(title): \(json)")
            if title == "final page", CommandLine.arguments.contains("--assert-aligned"),
               let requested = values["expectedPageOffset"] as? Double,
               let actual = values["scrollLeft"] as? Double,
               abs(requested - actual) > 1.5 {
                fputs("FAIL: final page was clamped by \(requested - actual) px\n", stderr)
                exit(2)
            }
            if let turn {
                self.web.evaluateJavaScript("folio.goPage(Math.max(0,folio.page+\(turn)));true") { _, error in
                    if let error { fputs("goPage: \(error)\n", stderr); exit(2) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.takeSnapshot("previous page", turn: nil)
                    }
                }
            } else {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let delegate = LastPageProbe()
    app.delegate = delegate
    app.run()
}
