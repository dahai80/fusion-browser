import Foundation

// FR-09: per-client read loop, frame timeout, large payload buffering, explicit backpressure.
// FR-09: single client large frame must NOT block other clients' small requests.
// B-4/R-6: partial-frame arrival timeout. A client that sends a length prefix claiming a
// large (but under-cap) frame then drips bytes (or goes silent) used to hold the buffer
// forever. append() now records when a partial frame first appears and signals `timeout`
// on a subsequent append if it stayed incomplete past frameTimeoutMs. The caller closes
// the connection and the buffer is cleared (no permanent 8MB hold).

public final class FBFrameReader {
    private let buffer = DispatchQueue(label: "fusion-browser.framereader", attributes: .concurrent)
    private var data = Data()
    private let maxFrameBytes: Int
    private let frameTimeoutMs: Int
    // Wall-clock instant a partial frame (length prefix read, body incomplete) first
    // appeared. Reset to nil whenever the buffer drains to a frame boundary.
    private var partialStartedAt: Date?
    private let log = FBLogger.shared

    public init(maxFrameBytes: Int = 8 * 1024 * 1024, frameTimeoutMs: Int = 30_000) {
        self.maxFrameBytes = maxFrameBytes
        self.frameTimeoutMs = frameTimeoutMs
    }

    // Append incoming bytes; return complete frames (without length prefix) ready to decode.
    // Synchronous: called on per-client serial queue.
    // - overflow: a single frame claims > maxFrameBytes -> backpressure drop, buffer cleared.
    // - timeout: a partial frame stayed incomplete past frameTimeoutMs -> caller closes conn,
    //   buffer cleared. Defends against the slow-drip partial-frame hold (B-4).
    public func append(_ chunk: Data) -> (frames: [Data], overflow: Bool, timeout: Bool) {
        var frames: [Data] = []
        var overflow = false
        var timeout = false
        data.append(chunk)
        while data.count >= 4 {
            let len = data.withUnsafeBytes { rawPtr -> UInt32 in
                let p = rawPtr.bindMemory(to: UInt8.self)
                return (UInt32(p[0]) << 24) | (UInt32(p[1]) << 16) | (UInt32(p[2]) << 8) | UInt32(p[3])
            }
            let frameLen = Int(len)
            if frameLen > maxFrameBytes {
                log.error("Framing", "frame \(frameLen) bytes > cap \(maxFrameBytes); backpressure drop")
                overflow = true
                partialStartedAt = nil
                data.removeAll()
                break
            }
            if data.count < 4 + frameLen {
                // Partial frame pending. Stamp the start instant on the first observation;
                // on later appends, check whether it has overstayed frameTimeoutMs.
                if partialStartedAt == nil {
                    partialStartedAt = Date()
                } else if let started = partialStartedAt,
                          Int(Date().timeIntervalSince(started) * 1000) > frameTimeoutMs {
                    log.warn("Framing", "partial frame \(frameLen)B incomplete after \(frameTimeoutMs)ms; timeout drop")
                    timeout = true
                    partialStartedAt = nil
                    data.removeAll()
                    break
                }
                break
            }
            let frame = data.subdata(in: 4..<(4 + frameLen))
            frames.append(frame)
            data.removeSubrange(0..<(4 + frameLen))
            // Drained to a frame boundary — a new partial (if any) restarts the clock.
            partialStartedAt = nil
        }
        return (frames, overflow, timeout)
    }

    public func reset() {
        data.removeAll()
        partialStartedAt = nil
    }
}
