import Foundation
import WebKit

/// Runs Google's Squoosh codecs (OxiPNG + libimagequant, compiled to WebAssembly)
/// inside a hidden WebKit view. The page in `Resources/Squoosh` keeps a pool of
/// Web Workers, so several images compress in parallel.
@MainActor
final class SquooshEngine: NSObject {
    static let shared = SquooshEngine()

    enum EngineError: LocalizedError {
        case missingResources
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .missingResources: return "Squoosh codecs are missing from the app bundle."
            case .failed(let message): return "Squoosh: \(message)"
            }
        }
    }

    private var webView: WKWebView?
    private var readyTask: Task<Void, Error>?
    private var loadContinuation: CheckedContinuation<Void, Error>?

    static var resourceDirectory: URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Squoosh"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("index.html").path) {
            return bundled
        }
        // Running from `swift run` during development.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Squoosh")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }

    /// Loads the engine page and waits for every worker to finish compiling the codecs.
    func prepare() async throws {
        if readyTask == nil {
            readyTask = Task { try await self.load() }
        }
        do {
            try await readyTask!.value
        } catch {
            readyTask = nil
            throw error
        }
    }

    private func load() async throws {
        guard let directory = Self.resourceDirectory else { throw EngineError.missingResources }

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(BundleSchemeHandler(root: directory), forURLScheme: BundleSchemeHandler.scheme)
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 16, height: 16), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView

        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            webView.load(URLRequest(url: URL(string: "\(BundleSchemeHandler.scheme)://engine/index.html")!))
        }
        _ = try await evaluate("return await window.chipngReady();", arguments: [:])
    }

    /// libimagequant ("Reduce palette" in Squoosh). Returns remapped RGBA pixels.
    func quantize(_ image: RGBAImage, colors: Int, dither: Double) async throws -> RGBAImage {
        let output = try await run("quantize", image, options: ["colors": colors, "dither": dither])
        guard output.count == image.pixels.count else { throw EngineError.failed("unexpected quantizer output") }
        return RGBAImage(width: image.width, height: image.height, pixels: [UInt8](output))
    }

    /// OxiPNG with alpha optimisation disabled. Returns an optimised PNG file.
    func oxipng(_ image: RGBAImage, level: Int) async throws -> Data {
        try await run("oxipng", image, options: ["level": level])
    }

    private func run(_ op: String, _ image: RGBAImage, options: [String: Any]) async throws -> Data {
        try await prepare()
        let input = Data(image.pixels).base64EncodedString()
        let result = try await evaluate(
            "return await window.chipngRun(op, input, width, height, options);",
            arguments: ["op": op, "input": input, "width": image.width, "height": image.height, "options": options]
        )
        guard let base64 = result as? String, let data = Data(base64Encoded: base64) else {
            throw EngineError.failed("no data returned")
        }
        return data
    }

    private func evaluate(_ script: String, arguments: [String: Any]) async throws -> Any? {
        guard let webView else { throw EngineError.failed("engine not loaded") }
        do {
            return try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
            throw EngineError.failed(message ?? error.localizedDescription)
        }
    }
}

extension SquooshEngine: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            loadContinuation?.resume()
            loadContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            loadContinuation?.resume(throwing: error)
            loadContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            loadContinuation?.resume(throwing: error)
            loadContinuation = nil
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Reload lazily on the next request.
        MainActor.assumeIsolated {
            self.webView = nil
            readyTask = nil
        }
    }
}

/// Serves the engine page, scripts and .wasm files from the app bundle.
private final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "chipng"
    let root: URL

    init(root: URL) { self.root = root }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let relative = url.path.split(separator: "/").filter { $0 != ".." }.joined(separator: "/")
        let file = root.appendingPathComponent(relative)
        guard let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime: String
        switch file.pathExtension {
        case "html": mime = "text/html"
        case "js": mime = "text/javascript"
        case "wasm": mime = "application/wasm"
        default: mime = "application/octet-stream"
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)", "Access-Control-Allow-Origin": "*"]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
