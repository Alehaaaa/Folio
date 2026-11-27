// Diagnostic of the actual macOS WKWebView reader with a local, user-owned EPUB
// chapter. No network access or changes to Folio's library.
// swiftc -o /tmp/folio-reader-live checks/reader-webkit-live.swift -framework AppKit -framework WebKit
// /tmp/folio-reader-live "path/to/chapter001.xhtml"
import AppKit
import WebKit
import ImageIO

@MainActor final class ReaderWebKitProbe: NSObject, NSApplicationDelegate,
    WKNavigationDelegate, WKScriptMessageHandler {
    private var web: WKWebView!
    private var window: NSWindow!
    private let config: [String: Any] = [
        "mode": "pages", "margin": 56, "fontSize": 32, "font": "'Iowan Old Style', serif",
        "columns": false, "comic": false, "bg": "#27251C", "fg": "#EDE5C8",
        "accent": "#E5C55A", "justify": false, "bold": false
    ]
    private var steps = 0
    private var bookRoot: URL!
    private var decorationRequests = 0
    private var negativeImageTest: Bool { CommandLine.arguments.contains("--negative") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("probe: app launched")
        guard CommandLine.arguments.count >= 2 else { fatalError("Pass an actual local EPUB chapter path") }
        let file = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        bookRoot = file.deletingLastPathComponent().deletingLastPathComponent()
        let sourceFile = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Core/ReaderScript.swift")
        let contents = try! String(contentsOf: sourceFile, encoding: .utf8)
        let beginning = contents.range(of: "#\"\"\"\n")!.upperBound
        let ending = contents.range(of: "\n\"\"\"#", range: beginning..<contents.endIndex)!.lowerBound
        let source = String(contents[beginning..<ending])

        let userContent = WKUserContentController()
        userContent.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        userContent.add(self, name: "folio")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContent
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 970, height: 720), configuration: configuration)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        window = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: 970, height: 720),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        window.orderFront(nil)
        _ = web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent().deletingLastPathComponent())
        DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
            if self.steps < 4 {
                fputs("Timed out in real WebKit test\n", stderr)
                exit(2)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("probe: navigation finished")
        let configData = try! JSONSerialization.data(withJSONObject: config)
        let json = String(data: configData, encoding: .utf8)!
        web.evaluateJavaScript("window.requestAnimationFrame=(callback)=>setTimeout(callback,0); folio.apply(\(json), {kind:'fraction',value:0.26}, 99); true") {
            _, error in
            if let error { fputs("apply error \(error)\n", stderr); exit(2) }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let payload = message.body as? [String: Any], payload["type"] as? String == "decorate" {
            bridgeDecoration(payload)
            return
        }
        if let payload = message.body as? [String: Any], payload["type"] as? String == "pos" {
            print("probe: position \(payload["page"] ?? "?")")
        }
        guard let payload = message.body as? [String: Any],
              payload["type"] as? String == "ready" else { return }
        if negativeImageTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.web.evaluateJavaScript("""
                  (() => {
                    const img=document.querySelector('img');
                    if (!img) return {missingImage:true};
                    return {source:img.currentSrc, cached:folio.decorationCache.has(img),
                            rejected:folio.decorationRejected.has(img),
                            natural:[img.naturalWidth,img.naturalHeight]};
                  })()
                """) { response, error in
                    guard error == nil,
                          let values = response as? [String:Any],
                          let source = values["source"] as? String, source.hasPrefix("file://"),
                          values["cached"] as? Bool == false,
                          self.decorationRequests == 0 else {
                        fputs("FAILED: cover or photo recolored / fetched as ornament: \(response ?? "nil")\n",stderr)
                        exit(2)
                    }
                    print("negative image preserved:",values)
                    NSApplication.shared.terminate(nil)
                }
            }
            return
        }
        snapshot(label: "initial")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            var next = self.config
            next["fg"] = "#E8D9C0"
            next["bg"] = "#3A3127"
            self.restyle(next, label: "palette-only")
        }
    }

    /// Mirrors the production Reader.swift image bridge using actual local EPUB bytes.
    private func bridgeDecoration(_ body: [String: Any]) {
        guard let request = body["requestID"] as? Int,
              let path = body["src"] as? String,
              let url = URL(string: path), url.isFileURL else { return }
        var result: String?
        let root = bookRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        if decorationRequests < 24 && file.path.hasPrefix(root),
           let mime = ["jpg":"image/jpeg","jpeg":"image/jpeg","png":"image/png",
                       "webp":"image/webp","gif":"image/gif","bmp":"image/bmp"][file.pathExtension.lowercased()],
           let data = try? Data(contentsOf: file), data.count <= 1_000_000,
           let decoded = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceGetCount(decoded) == 1,
           let properties = CGImageSourceCopyPropertiesAtIndex(decoded,0,nil) as? [CFString:Any],
           let w = properties[kCGImagePropertyPixelWidth] as? Int,
           let h = properties[kCGImagePropertyPixelHeight] as? Int,
           w <= 640 && h <= 640 && w*h <= 200000 {
            result = "data:\(mime);base64,\(data.base64EncodedString())"
            decorationRequests += 1
            print("bridge accepted",file.lastPathComponent, "\(w)x\(h)")
        }
        let json = String(data: try! JSONEncoder().encode(result), encoding: .utf8)!
        web.evaluateJavaScript("folio.receiveDecorationData(\(request), \(json))") { _, error in
            if let error { print("bridge reply error",error) }
        }
    }

    private func restyle(_ config: [String: Any], label: String) {
        let json = String(data: try! JSONSerialization.data(withJSONObject: config), encoding: .utf8)!
        web.evaluateJavaScript("folio.restyle(\(json)); true") { _, error in
            if let error { fputs("restyle error \(error)\n", stderr); exit(2) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.snapshot(label: label)
                self.steps += 1
                if self.steps == 1 {
                    var next = self.config
                    next["fontSize"] = 27
                    next["font"] = "Georgia, serif"
                    next["bg"] = "#2C2B29"
                    next["fg"] = "#D9D5CC"
                    self.restyle(next, label: "font+theme")
                } else if self.steps == 2 {
                    self.steps = 4
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApplication.shared.terminate(nil) }
                }
            }
        }
    }

    private func snapshot(label: String) {
        let js = #"""
          (() => {
            let img = document.querySelector('img.orn');
            let a = folio.captureVisibleAnchor();
            if (!window.__folioOriginalAnchor) window.__folioOriginalAnchor = a;
            let original = window.__folioOriginalAnchor;
            let r = null;
            if (a.node) {
              let range = document.createRange();
              range.setStart(a.node,a.offset);
              range.setEnd(a.node,Math.min(a.node.length,a.offset+1));
              let rect = range.getBoundingClientRect();
              r = {left:rect.left,top:rect.top};
            }
            let o = null;
            if (original.node) {
              let range = document.createRange();
              range.setStart(original.node, original.offset);
              range.setEnd(original.node, Math.min(original.node.length, original.offset+1));
              let rr = range.getBoundingClientRect();
              o = {left:rr.left,right:rr.right,top:rr.top,bottom:rr.bottom,
                isVisible:rr.right>=0 && rr.left<=innerWidth && rr.bottom>=0 && rr.top<=innerHeight,
                text:original.node.nodeValue.slice(original.offset,original.offset+44)};
            }
            let canvasError = null;
            let imageStats = null;
            if (img) {
              try {
                let canvas = document.createElement('canvas');
                canvas.width = img.naturalWidth;
                canvas.height = img.naturalHeight;
                canvas.getContext('2d').drawImage(img,0,0);
                let pixels = canvas.getContext('2d').getImageData(0,0,canvas.width,canvas.height).data;
                let transparent=0, opaque=0, matchingInk=0;
                let fg=[parseInt(folio.cfg.fg.slice(1,3),16),parseInt(folio.cfg.fg.slice(3,5),16),
                        parseInt(folio.cfg.fg.slice(5,7),16)];
                for(let i=0;i<pixels.length;i+=4){
                  if(pixels[i+3] < 8) transparent++;
                  if(pixels[i+3] > 200) {
                    opaque++;
                    if(Math.abs(pixels[i]-fg[0])<2 && Math.abs(pixels[i+1]-fg[1])<2 &&
                       Math.abs(pixels[i+2]-fg[2])<2) matchingInk++;
                  }
                }
                imageStats={transparent,opaque,matchingInk,total:pixels.length/4};
              } catch(e) { canvasError = e.name + ': ' + e.message; }
            }
            return {
              page:folio.page,pages:folio.pages,left:document.scrollingElement.scrollLeft,
              text:a.node ? a.node.nodeValue.slice(a.offset,a.offset+44) : null,
              rect:r,original:o,canvasError,imageStats,
              img:img ? {class:img.className, src:img.src.slice(0,60),
                natural:[img.naturalWidth,img.naturalHeight], rect:img.getBoundingClientRect().toJSON(),
                cached:folio.decorationCache.has(img),rejected:folio.decorationRejected.has(img)} : null
            }
          })()
        """#
        web.evaluateJavaScript(js) { result, error in
            if let error { print("\(label): ERROR \(error)"); return }
            if label != "initial" {
                guard let observation = result as? [String:Any],
                      let image = observation["img"] as? [String:Any],
                      image["cached"] as? Bool == true,
                      let stats = observation["imageStats"] as? [String:Int],
                      let total = stats["total"], total > 0,
                      let transparent = stats["transparent"], transparent > total * 60 / 100,
                      let opaque = stats["opaque"], opaque > total * 5 / 100,
                      let matching = stats["matchingInk"], matching == opaque else {
                    fputs("FAILED: ornament not transparent/foreground-colored in \(label)\n",stderr)
                    exit(2)
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: result ?? NSNull(), options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                print("\(label): \(json)")
            }
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let delegate = ReaderWebKitProbe()
    app.delegate = delegate
    app.run()
}
