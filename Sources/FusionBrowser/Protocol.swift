import Foundation

// FR-11 / §3.2 Protobuf schema mapped to Swift Codable.
// Phase 1 wire codec = length-prefixed JSON (D12 eval deferred to gRPC).
// Schema shape stable: swapping codec later must not break these types.

public enum WebMode: String, Codable {
    case headless
    case headed
}

public enum ActionType: String, Codable {
    case click
    case typeText = "type_text"
    case scroll
    case navigate
    case screenshot
    case evaluate
    case close
}

public struct SecurityAuditResult: Codable, Equatable {
    public var nodesAudited: Int
    public var hiddenNodesPurged: Int
    public var matchedRules: [String]

    public init(nodesAudited: Int = 0, hiddenNodesPurged: Int = 0, matchedRules: [String] = []) {
        self.nodesAudited = nodesAudited
        self.hiddenNodesPurged = hiddenNodesPurged
        self.matchedRules = matchedRules
    }
}

public struct AXTreeNode: Codable, Equatable {
    public var nodeId: String
    public var role: String
    public var name: String
    public var isDisabled: Bool
    public var currentValue: String
    // Issue #9: viewport-relative bounding box (getBoundingClientRect). Additive,
    // optional for backward compat (nil only if source omitted it). Lets SOM /
    // visual-grounding consumers draw overlays without a re-walk.
    public var bbox: FBBBox?

    public init(nodeId: String, role: String, name: String, isDisabled: Bool,
                currentValue: String, bbox: FBBBox? = nil) {
        self.nodeId = nodeId
        self.role = role
        self.name = name
        self.isDisabled = isDisabled
        self.currentValue = currentValue
        self.bbox = bbox
    }
}

public struct CreateSessionRequest: Codable {
    public var mode: WebMode
    public var initialUrl: String?
    public var maxActions: Int?
    public var taskTimeoutMs: Int?
    public var credentialDomain: String?
    // Issue #25: persistent profile per workflow run. nil = today's nonPersistent store
    // (FR-04 default path unchanged). Non-nil requires the .persistentProfiles cap and a
    // token-attributable caller (owner = auth-token hash).
    public var profileId: String?

    public init(mode: WebMode = .headless, initialUrl: String? = nil, maxActions: Int? = nil,
                taskTimeoutMs: Int? = nil, credentialDomain: String? = nil,
                profileId: String? = nil) {
        self.mode = mode
        self.initialUrl = initialUrl
        self.maxActions = maxActions
        self.taskTimeoutMs = taskTimeoutMs
        self.credentialDomain = credentialDomain
        self.profileId = profileId
    }
}

public struct CreateSessionResponse: Codable {
    public var sessionId: String
    public var credentialInjected: Bool

    public init(sessionId: String, credentialInjected: Bool) {
        self.sessionId = sessionId
        self.credentialInjected = credentialInjected
    }
}

// Issue #25: import cookies from the user's browser into a live session.
public struct ImportCookiesRequest: Codable {
    public var sessionId: String
    public var browser: String
    public var profile: String?

    public init(sessionId: String, browser: String, profile: String? = nil) {
        self.sessionId = sessionId
        self.browser = browser
        self.profile = profile
    }
}

public struct ImportCookiesResponse: Codable {
    public var sessionId: String
    public var browser: String
    public var imported: Int
    public var skippedAppBound: Int
    public var skippedOther: Int

    public init(sessionId: String, browser: String, imported: Int,
                skippedAppBound: Int, skippedOther: Int) {
        self.sessionId = sessionId
        self.browser = browser
        self.imported = imported
        self.skippedAppBound = skippedAppBound
        self.skippedOther = skippedOther
    }
}

// Issue #25: screenshot stream subscription (frames pushed on the subscribing connection).
public struct StreamScreenshotsRequest: Codable {
    public var sessionId: String
    public var enabled: Bool

    public init(sessionId: String, enabled: Bool) {
        self.sessionId = sessionId
        self.enabled = enabled
    }
}

public struct StreamAckResponse: Codable {
    public var sessionId: String
    public var active: Bool

    public init(sessionId: String, active: Bool) {
        self.sessionId = sessionId
        self.active = active
    }
}

// Issue #25: delete a persistent profile (owner or system caller only).
public struct DeleteProfileRequest: Codable {
    public var profileId: String

    public init(profileId: String) {
        self.profileId = profileId
    }
}

public struct ProfileDeletedResponse: Codable {
    public var profileId: String
    public var deleted: Bool

    public init(profileId: String, deleted: Bool) {
        self.profileId = profileId
        self.deleted = deleted
    }
}

// Issue #25: server-pushed stream frames. Their own envelopes (never FBResponse) so
// request/response clients that did not subscribe never see them; the `type` field is
// the discriminator. png is base64 on the wire (Data codable default).
public struct ScreenshotFrameEvent: Codable {
    public var type: String
    public var sessionId: String
    public var seq: Int
    public var png: Data
    public var url: String
    public var title: String
    public var tsMs: Int

    public init(sessionId: String, seq: Int, png: Data, url: String, title: String, tsMs: Int) {
        self.type = "screenshot_frame"
        self.sessionId = sessionId
        self.seq = seq
        self.png = png
        self.url = url
        self.title = title
        self.tsMs = tsMs
    }
}

public struct StreamEndEvent: Codable {
    public var type: String
    public var sessionId: String
    public var reason: String

    public init(sessionId: String, reason: String) {
        self.type = "stream_end"
        self.sessionId = sessionId
        self.reason = reason
    }
}

public struct BrowserActionRequest: Codable {
    public var sessionId: String
    public var action: ActionType
    public var targetNodeId: String?
    public var payloadText: String?
    public var scrollDeltaY: Double?
    public var traceId: String?

    public init(sessionId: String, action: ActionType, targetNodeId: String? = nil,
                payloadText: String? = nil, scrollDeltaY: Double? = nil, traceId: String? = nil) {
        self.sessionId = sessionId
        self.action = action
        self.targetNodeId = targetNodeId
        self.payloadText = payloadText
        self.scrollDeltaY = scrollDeltaY
        self.traceId = traceId
    }
}

public struct BrowserStateResponse: Codable {
    public var sessionId: String
    public var url: String
    public var title: String
    public var axTreeMarkdown: String
    public var interactiveNodes: [AXTreeNode]
    // E-7: screenshotJpeg was a dead field (the .screenshot action fell through to a
    // plain AXTree extract and never captured an image). Kept as a legacy nil for
    // wire-schema backward compat; the live capture now populates screenshotPng (WKWebView
    // takeSnapshot emits PNG, not JPEG — the old field name lied about the format too).
    public var screenshotJpeg: Data?
    public var screenshotPng: Data?
    public var hasSecurityInjectionBlocked: Bool
    public var executionTimeMs: Int
    public var securityAudit: SecurityAuditResult?
    public var sessionRecovered: Bool
    public var error: FBError?
    public var traceId: String?
    // E-9: real Runtime.evaluate result. JSON-encoded form of the JS expression's return
    // value (NSString/NSNumber/NSNull/NSArray/NSDictionary from WKWebView JSON deserialization).
    // nil for non-evaluate actions, or when the eval returned undefined/threw/timed out.
    // CDP handleEvaluate decodes this into {result:{type,value}}; UDS callers may read it too.
    public var evaluateResult: String?

    public init(sessionId: String, url: String, title: String, axTreeMarkdown: String,
                interactiveNodes: [AXTreeNode], screenshotJpeg: Data? = nil,
                screenshotPng: Data? = nil,
                hasSecurityInjectionBlocked: Bool = false, executionTimeMs: Int = 0,
                securityAudit: SecurityAuditResult? = nil, sessionRecovered: Bool = false,
                error: FBError? = nil, traceId: String? = nil,
                evaluateResult: String? = nil) {
        self.sessionId = sessionId
        self.url = url
        self.title = title
        self.axTreeMarkdown = axTreeMarkdown
        self.interactiveNodes = interactiveNodes
        self.screenshotJpeg = screenshotJpeg
        self.screenshotPng = screenshotPng
        self.hasSecurityInjectionBlocked = hasSecurityInjectionBlocked
        self.executionTimeMs = executionTimeMs
        self.securityAudit = securityAudit
        self.sessionRecovered = sessionRecovered
        self.error = error
        self.traceId = traceId
        self.evaluateResult = evaluateResult
    }
}

// R-3/B-3: read-only engine metrics response. counters = [name,value] pairs,
// latency = per-key {count,p50_ms,p95_ms}. Populated by FBMetrics.metricsArray().
public struct MetricsResponse: Codable {
    public var counters: [FBMetrics.FBMetric]
    public var latency: [FBMetrics.FBMetric]

    public init(counters: [FBMetrics.FBMetric] = [], latency: [FBMetrics.FBMetric] = []) {
        self.counters = counters
        self.latency = latency
    }
}

// Top-level envelope so server can route CreateSession / Execute / Close / Metrics.
public enum FBRequest: Codable {
    case createSession(CreateSessionRequest)
    case execute(BrowserActionRequest)
    case close(sessionId: String)
    case metrics
    case capacity
    case importCookies(ImportCookiesRequest)
    case streamScreenshots(StreamScreenshotsRequest)
    case deleteProfile(DeleteProfileRequest)

    private enum CodingKeys: String, CodingKey { case type, payload, sessionId }
    private enum ReqType: String, Codable {
        case createSession = "create_session", execute, close, metrics, capacity
        case importCookies = "import_cookies"
        case streamScreenshots = "stream_screenshots"
        case deleteProfile = "delete_profile"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(ReqType.self, forKey: .type)
        switch type {
        case .createSession:
            let p = try c.decode(CreateSessionRequest.self, forKey: .payload)
            self = .createSession(p)
        case .execute:
            let p = try c.decode(BrowserActionRequest.self, forKey: .payload)
            self = .execute(p)
        case .close:
            let sid = try c.decode(String.self, forKey: .sessionId)
            self = .close(sessionId: sid)
        case .metrics:
            self = .metrics
        case .capacity:
            self = .capacity
        case .importCookies:
            self = .importCookies(try c.decode(ImportCookiesRequest.self, forKey: .payload))
        case .streamScreenshots:
            self = .streamScreenshots(try c.decode(StreamScreenshotsRequest.self, forKey: .payload))
        case .deleteProfile:
            self = .deleteProfile(try c.decode(DeleteProfileRequest.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .createSession(let p):
            try c.encode(ReqType.createSession, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .execute(let p):
            try c.encode(ReqType.execute, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .close(let sid):
            try c.encode(ReqType.close, forKey: .type)
            try c.encode(sid, forKey: .sessionId)
        case .metrics:
            try c.encode(ReqType.metrics, forKey: .type)
        case .capacity:
            try c.encode(ReqType.capacity, forKey: .type)
        case .importCookies(let p):
            try c.encode(ReqType.importCookies, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .streamScreenshots(let p):
            try c.encode(ReqType.streamScreenshots, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .deleteProfile(let p):
            try c.encode(ReqType.deleteProfile, forKey: .type)
            try c.encode(p, forKey: .payload)
        }
    }

    public var traceId: String? {
        switch self {
        case .execute(let r): return r.traceId
        default: return nil
        }
    }
}

public enum FBResponse: Codable {
    case createSession(CreateSessionResponse)
    case state(BrowserStateResponse)
    case closed(sessionId: String)
    case metrics(MetricsResponse)
    case capacity(FBNodeCapacity)
    case error(FBError)
    case importCookies(ImportCookiesResponse)
    case streamAck(StreamAckResponse)
    case profileDeleted(ProfileDeletedResponse)

    private enum CodingKeys: String, CodingKey { case type, payload, sessionId }
    private enum RespType: String, Codable {
        case createSession = "create_session", state, closed, metrics, capacity, error
        case importCookies = "import_cookies"
        case streamAck = "stream_ack"
        case profileDeleted = "profile_deleted"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(RespType.self, forKey: .type)
        switch type {
        case .createSession:
            self = .createSession(try c.decode(CreateSessionResponse.self, forKey: .payload))
        case .state:
            self = .state(try c.decode(BrowserStateResponse.self, forKey: .payload))
        case .closed:
            self = .closed(sessionId: try c.decode(String.self, forKey: .sessionId))
        case .metrics:
            self = .metrics(try c.decode(MetricsResponse.self, forKey: .payload))
        case .capacity:
            self = .capacity(try c.decode(FBNodeCapacity.self, forKey: .payload))
        case .error:
            self = .error(try c.decode(FBError.self, forKey: .payload))
        case .importCookies:
            self = .importCookies(try c.decode(ImportCookiesResponse.self, forKey: .payload))
        case .streamAck:
            self = .streamAck(try c.decode(StreamAckResponse.self, forKey: .payload))
        case .profileDeleted:
            self = .profileDeleted(try c.decode(ProfileDeletedResponse.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .createSession(let p):
            try c.encode(RespType.createSession, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .state(let p):
            try c.encode(RespType.state, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .closed(let sid):
            try c.encode(RespType.closed, forKey: .type)
            try c.encode(sid, forKey: .sessionId)
        case .metrics(let p):
            try c.encode(RespType.metrics, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .capacity(let p):
            try c.encode(RespType.capacity, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .error(let e):
            try c.encode(RespType.error, forKey: .type)
            try c.encode(e, forKey: .payload)
        case .importCookies(let p):
            try c.encode(RespType.importCookies, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .streamAck(let p):
            try c.encode(RespType.streamAck, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .profileDeleted(let p):
            try c.encode(RespType.profileDeleted, forKey: .type)
            try c.encode(p, forKey: .payload)
        }
    }
}

// Length-prefixed framing: [u32 big-endian length][JSON payload].
// FR-09: per-client read loop, frame timeout, large payload sharding (decode side buffers).
// JSON keys = snake_case (matches Protobuf schema field names, cross-lang compatible).
public enum FBFrame {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let json = try encoder.encode(value)
        var data = Data(capacity: 4 + json.count)
        var len = UInt32(json.count).bigEndian
        withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
        data.append(json)
        return data
    }

    public static func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        return try decoder.decode(T.self, from: data)
    }
}
