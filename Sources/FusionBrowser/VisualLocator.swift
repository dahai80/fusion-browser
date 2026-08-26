import Foundation

// T3.4: Visual grounding backup (FR: scenario 3). When the AXTree/stable mapping can't
// resolve a node (node_stale, no fingerprint match), fall back to a screenshot + VLM
// coordinate prediction via fusion-mlx's OpenAI-compatible /v1/chat/completions.
//
// Flow: screenshotSync PNG -> base64 data URI -> VLM with a "return {x,y} JSON" prompt ->
// parse the predicted centroid -> click at (x, y). This is a BEST-EFFORT fallback: the VLM
// may hallucinate, so callers treat a nil/ooB result as "couldn't locate" and surface the
// original node_stale error. Only invoked when DOM resolution fails, never as primary path.
//
// fusion-mlx is called read-only over HTTP (localhost:11434); this project never modifies
// it (monorepo rule). The VLM model must be loaded by fusion-mlx beforehand — see config
// `vlmModel` (default "mlx-community/Qwen3-VL-2B-Instruct" when available).

public struct FBVisualLocatorConfig: Codable, Equatable {
    public var endpoint: String       // e.g. http://127.0.0.1:11434
    public var model: String          // VLM model id loaded by fusion-mlx
    public var timeoutMs: Int         // HTTP timeout for the prediction call
    public var enabled: Bool

    public init(endpoint: String = "http://127.0.0.1:11434",
                model: String = "mlx-community/Qwen3-VL-2B-Instruct",
                timeoutMs: Int = 30_000, enabled: Bool = false) {
        self.endpoint = endpoint
        self.model = model
        self.timeoutMs = timeoutMs
        self.enabled = enabled
    }
}

public struct FBPredictedCoord: Equatable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

// Pluggable HTTP transport so the predictor is unit-testable without a live model
// (fusion-mlx VLM load is integration-only; per project rule LLM tests must real-load).
public protocol FBHTTPClient {
    func post(url: String, body: Data, timeoutMs: Int) -> Data?
}

// URLSession-backed default client.
public final class FBURLSessionHTTPClient: FBHTTPClient {
    public init() {}
    public func post(url: String, body: Data, timeoutMs: Int) -> Data? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = TimeInterval(timeoutMs) / 1000.0
        let sem = DispatchSemaphore(value: 0)
        var out: Data? = nil
        URLSession.shared.dataTask(with: req) { data, _, _ in
            out = data
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + .milliseconds(timeoutMs + 2_000))
        return out
    }
}

public final class FBVisualLocator {
    private let config: FBVisualLocatorConfig
    private let client: FBHTTPClient
    private let log = FBLogger.shared

    public init(config: FBVisualLocatorConfig, client: FBHTTPClient = FBURLSessionHTTPClient()) {
        self.config = config
        self.client = client
    }

    // Predict the click centroid for `description` within a screenshot of `viewportSize`.
    // Returns nil on disabled / HTTP failure / unparseable / out-of-bounds coords.
    // screenshot: PNG bytes from FBWebView.screenshotSync. viewportSize for OOB validation.
    public func predict(screenshot: Data, description: String, viewportSize: (w: Int, h: Int)) -> FBPredictedCoord? {
        guard config.enabled else { return nil }
        guard !screenshot.isEmpty, !description.isEmpty else { return nil }
        let body = buildRequestBody(screenshot: screenshot, description: description, viewportSize: viewportSize)
        guard let resp = client.post(url: config.endpoint + "/v1/chat/completions", body: body, timeoutMs: config.timeoutMs) else {
            log.warn("Visual", "predict HTTP failed endpoint=\(config.endpoint)")
            return nil
        }
        guard let text = extractAssistantText(resp) else {
            log.warn("Visual", "predict response had no choices.content")
            return nil
        }
        guard let coord = parseCoord(from: text) else {
            log.warn("Visual", "predict unparseable coords text=\(text.prefix(120))")
            return nil
        }
        // Out-of-bounds guard: VLM may hallucinate past the viewport.
        if coord.x < 0 || coord.y < 0 || coord.x > Double(viewportSize.w) || coord.y > Double(viewportSize.h) {
            log.warn("Visual", "predict oob x=\(coord.x) y=\(coord.y) vp=\(viewportSize)")
            return nil
        }
        log.info("Visual", "predict ok desc=\(description.prefix(40)) x=\(coord.x) y=\(coord.y)")
        return coord
    }

    // Build the OpenAI-compatible chat completion body with a data-URI image + a JSON
    // coordinate-extraction prompt. fusion-mlx's VLM engine reads image_url.url (base64
    // data URIs are accepted by mlx_vlm).
    func buildRequestBody(screenshot: Data, description: String, viewportSize: (w: Int, h: Int)) -> Data {
        let b64 = screenshot.base64EncodedString()
        let dataUri = "data:image/png;base64,\(b64)"
        let prompt = """
        You are a visual grounding model for web automation. The image is a browser screenshot of size \(viewportSize.w)x\(viewportSize.h) px, origin top-left. Find the clickable element best matching: "\(description)". Respond ONLY with a JSON object {"x": <number>, "y": <number>} giving the click centroid in pixel coordinates. No prose.
        """
        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "user", "content": [
                    ["type": "text", "text": prompt],
                    ["type": "image_url", "image_url": ["url": dataUri]],
                ]],
            ],
            "max_tokens": 64,
            "temperature": 0.1,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return Data() }
        return data
    }

    // Extract the assistant message text from a chat completion response.
    func extractAssistantText(_ resp: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: resp) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else { return nil }
        return message["content"] as? String
    }

    // Parse {"x":..,"y":..} out of the model text, tolerating surrounding prose/code fences.
    func parseCoord(from text: String) -> FBPredictedCoord? {
        // Find the first {...} block and parse it.
        guard let start = text.firstIndex(of: "{"),
              let end = text[start...].firstIndex(of: "}") else { return nil }
        let jsonStr = String(text[start...end])
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let x = (obj["x"] as? Double) ?? Double(obj["x"] as? Int ?? 0)
        let y = (obj["y"] as? Double) ?? Double(obj["y"] as? Int ?? 0)
        return FBPredictedCoord(x: x, y: y)
    }
}
